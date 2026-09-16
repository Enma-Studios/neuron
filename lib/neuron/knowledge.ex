defmodule Neuron.Knowledge do
  @moduledoc "Shared, evidence-first graph ingestion and deterministic claim reconciliation."
  def id(kind, value),
    do: "_:#{kind}-" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  def canonical_url(url) do
    uri = URI.parse(url)
    true = uri.scheme in ["http", "https"] and is_binary(uri.host)

    %{uri | host: String.downcase(uri.host), fragment: nil}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  def domain(value) do
    uri = URI.parse(if String.contains?(value, "://"), do: value, else: "https://" <> value)
    String.downcase(uri.host || "") |> String.trim_leading("www.")
  end

  # ponytail: a short list of two-level public suffixes, not the Public
  # Suffix List; a seller on a suffix missing here gets one label too few.
  # Add the list as a dependency if sellers outside these show up.
  @two_level_suffixes ~w(co.uk org.uk ac.uk gov.uk me.uk com.au net.au org.au co.nz org.nz co.jp com.br co.in com.sg co.za com.mx com.cn com.tr com.ar)

  @doc """
  The registrable domain of a URL or host: `https://careers.booking.com/x`
  is `booking.com`, `shop.example.co.uk` is `example.co.uk`. `nil` when the
  value is not a hostname at all.
  """
  def registrable_domain(value) when is_binary(value) do
    host = domain(value)

    if Regex.match?(~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/, host) do
      labels = String.split(host, ".")
      keep = if Enum.join(Enum.take(labels, -2), ".") in @two_level_suffixes, do: 3, else: 2
      labels |> Enum.take(-keep) |> Enum.join(".")
    end
  end

  def registrable_domain(_), do: nil

  def entity_id("Organization", identity), do: id("org", domain(identity))
  def entity_id(type, "urn:" <> _ = identity), do: id(String.downcase(type), identity)
  def entity_id(type, identity), do: id(String.downcase(type), canonical_url(identity))

  @doc "Record an explicit caller assertion; it overrides observed values but is not contact verification."
  def assert_fact(attrs, opts \\ []) do
    value = Map.get(attrs, :value, Map.get(attrs, "value"))

    attrs =
      attrs
      |> Map.put(:excerpt, value)
      |> Map.put(:source_url, "urn:neuron:user")

    with {:ok, claim} <- Neuron.Contracts.validate(Neuron.Contracts.Claim, attrs) do
      entity = entity_id(claim.entity_type, claim.identity)

      node = %{
        "uid" => entity,
        "dgraph.type" => [claim.entity_type, "Entity"],
        "assertions" => [
          %{
            "uid" => id("user-assertion", entity <> claim.predicate <> claim.value),
            "dgraph.type" => ["Assertion", "Entity"],
            "predicate" => claim.predicate,
            "claim_value" => claim.value,
            "excerpt" => claim.value,
            "url" => "urn:neuron:user",
            "assertion_kind" => "user",
            "authority" => 1.0,
            "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      }

      with :ok <- Neuron.Graph.upsert(node, opts), do: reconcile(entity, opts)
    end
  end

  def save_document(document, opts) do
    url = canonical_url(document.url)
    hash = Base.encode16(:crypto.hash(:sha256, document.markdown), case: :lower)
    snapshot_id = id("document", url <> hash)

    graph = %{
      "uid" => id("source", url),
      "dgraph.type" => ["Source", "Entity"],
      "url" => url,
      "title" => document.title,
      "fetched_at" => DateTime.to_iso8601(document.fetched_at),
      "documents" => [
        %{
          "uid" => snapshot_id,
          "dgraph.type" => ["Snapshot", "Entity"],
          "url" => url,
          "markdown" => document.markdown,
          "content_hash" => hash,
          "extraction_version" => 1
        }
      ]
    }

    [snapshot] = graph["documents"]

    snapshot =
      Map.put(
        snapshot,
        "observed_at",
        DateTime.to_iso8601(document.published_at || document.fetched_at)
      )

    with :ok <- Neuron.Graph.insert_once(snapshot, opts),
         :ok <- Neuron.Graph.upsert(Map.put(graph, "documents", [%{"uid" => snapshot_id}]), opts),
         do: {:ok, snapshot_id}
  end

  @doc """
  Keep only claims with exact in-document evidence. A claim that fails any
  evidence check is dropped, not fatal: one flawed claim must not discard
  the rest of a page. An all-invalid page yields an empty claim list, which
  is a valid outcome — the snapshot is already saved as evidence.
  """
  def validate_claims(%{"claims" => claims}, document) when is_list(claims) do
    claims = own_site_people(claims, document)

    {kept, dropped} =
      Enum.split_with(claims, fn attrs ->
        match?({:ok, _}, supported_claim(attrs, document))
      end)

    if dropped != [] do
      Neuron.Telemetry.emit(
        [:knowledge, :claims_dropped],
        %{document: document.url, kept: length(kept), dropped: length(dropped)}
      )
    end

    kept_claims =
      Enum.map(kept, fn attrs ->
        {:ok, claim} = supported_claim(attrs, document)
        Neuron.Contracts.plain(claim)
      end)

    {:ok, kept_claims}
  end

  def validate_claims(_, _), do: {:error, :expected_claims_array}

  @doc """
  The identity of a person an organization names on its own site: stable
  per employer and name, since such a page links no profile to identify
  them by.
  """
  def person_urn(employer, name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    "urn:neuron:person:#{domain(employer)}:#{slug}"
  end

  # A leadership or team page often names people without linking a profile,
  # and is still the employer stating on its own domain who holds which
  # role. A person identified by name is kept when the same response gives
  # them an employer that owns the page and the name is on it; anywhere else
  # a name alone identifies nobody.
  defp own_site_people(claims, document) do
    host = domain(document.url)

    employers =
      for %{"entity_type" => "Person", "identity" => name, "predicate" => "employer"} = claim <-
            claims,
          is_binary(name) and String.trim(name) != "" and not valid_http_url?(name),
          is_binary(claim["value"]),
          owns?(domain(claim["value"]), host),
          String.contains?(document.markdown, name),
          into: %{},
          do: {name, claim["value"]}

    Enum.map(claims, fn
      %{"entity_type" => "Person", "identity" => name} = claim
      when is_map_key(employers, name) ->
        Map.put(claim, "identity", person_urn(employers[name], name))

      claim ->
        claim
    end)
  end

  defp owns?("", _host), do: false
  defp owns?(employer, host), do: host == employer or String.ends_with?(host, "." <> employer)

  defp urn_employer("urn:neuron:person:" <> rest),
    do: rest |> String.split(":") |> List.first()

  defp urn_employer(_), do: nil

  defp supported_claim(attrs, document) when is_map(attrs) do
    with {:ok, claim} <- Neuron.Contracts.validate(Neuron.Contracts.Claim, attrs),
         true <- claim.source_url == document.url,
         true <- String.contains?(document.markdown, claim.excerpt),
         true <- identity_supported?(claim, document),
         true <-
           claim.predicate != "email" or
             String.contains?(String.downcase(claim.excerpt), String.downcase(claim.value)),
         true <-
           claim.entity_type == "Organization" or
             String.starts_with?(claim.identity, ["https://", "http://"]) or
             own_site_identity?(claim, document) do
      {:ok, claim}
    else
      false -> {:error, :unsupported_claim}
      error -> error
    end
  end

  defp supported_claim(_, _document), do: {:error, :unsupported_claim}

  defp identity_supported?(claim, document) do
    case claim.entity_type do
      # Organizations are identified by their domain, bare or as a URL.
      "Organization" ->
        domain_identity?(claim.identity) and
          (domain(claim.identity) == domain(document.url) or
             String.contains?(document.markdown, claim.identity))

      _ ->
        own_site_identity?(claim, document) or
          (valid_http_url?(claim.identity) and
             (canonical_url(claim.identity) == canonical_url(document.url) or
                String.contains?(document.markdown, claim.identity)))
    end
  end

  defp own_site_identity?(claim, document) do
    case urn_employer(claim.identity) do
      nil -> false
      employer -> owns?(employer, domain(document.url))
    end
  end

  defp domain_identity?(value) when is_binary(value) and value != "" do
    if String.contains?(value, "://"), do: valid_http_url?(value), else: domain(value) != ""
  end

  defp domain_identity?(_), do: false

  defp valid_http_url?(value) when is_binary(value),
    do: String.starts_with?(value, ["https://", "http://"])

  defp valid_http_url?(_), do: false

  def ingest(claims, document, snapshot_id, opts) do
    {:ok, %{"snapshots" => [snapshot]}} =
      Neuron.Graph.query(
        "query snapshot($id: string) { snapshots(func: eq(external_id, $id)) { observed_at } }",
        %{"$id" => snapshot_id},
        opts
      )

    nodes =
      Enum.map(claims, fn claim ->
        entity = entity_id(claim.entity_type, claim.identity)
        claim_id = id("claim", entity <> claim.predicate <> claim.value <> snapshot_id)

        %{
          "uid" => entity,
          "dgraph.type" => [claim.entity_type, "Entity"],
          "assertions" => [
            %{
              "uid" => claim_id,
              "dgraph.type" => ["Assertion", "Entity"],
              "predicate" => claim.predicate,
              "claim_value" => claim.value,
              "excerpt" => claim.excerpt,
              "url" => document.url,
              "observed_at" => snapshot["observed_at"],
              "authority" => authority(claim, document),
              "assertion_kind" => "observed",
              "documents" => [%{"uid" => snapshot_id}],
              # The Source of the document this claim was read from. Without
              # it a claim cannot be traced back to what it was read from,
              # and its excerpt cannot be checked against that document.
              "sources" => [%{"uid" => id("source", canonical_url(document.url))}],
              "subject" => %{"uid" => entity}
            }
          ]
        }
        |> identify(claim)
      end)

    with :ok <- Neuron.Graph.upsert(nodes, opts) do
      claims
      |> Enum.sort_by(&if(&1.entity_type == "Organization", do: 0, else: 1))
      |> Enum.map(&entity_id(&1.entity_type, &1.identity))
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn entity, :ok ->
        case reconcile(entity, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # An organization's domain, or a person's profile URL. A person named on
  # their employer's own page has no profile URL to record.
  defp identify(node, %{entity_type: "Organization"} = claim),
    do: Map.put(node, "domain", domain(claim.identity))

  defp identify(node, claim) do
    if valid_http_url?(claim.identity),
      do: Map.put(node, "profile_url", canonical_url(claim.identity)),
      else: node
  end

  defp authority(claim, document) do
    host = domain(document.url)

    cond do
      # The employer naming its own people on its own domain.
      (employer = urn_employer(claim.identity)) && owns?(employer, host) ->
        1.0

      claim.predicate == "employer" and domain(claim.value) == host ->
        1.0

      claim.predicate == "email" and String.ends_with?(String.downcase(claim.value), "@" <> host) ->
        1.0

      host == domain(claim.identity) ->
        1.0

      host in ["linkedin.com", "x.com", "twitter.com"] ->
        0.8

      true ->
        0.5
    end
  end

  def reconcile(entity, opts) do
    with {:ok, %{"records" => [record]}} <-
           Neuron.Graph.query(
             "query entity($id: string) { records(func: eq(external_id, $id)) { uid assertions { uid predicate claim_value excerpt url observed_at authority assertion_kind } } }",
             %{"$id" => entity},
             opts
           ) do
      claims = record["assertions"] || []
      current = resolve(claims)
      facts = Map.new(current, fn {predicate, claim} -> {predicate, claim["claim_value"]} end)
      refs = Enum.map(current, fn {_, c} -> %{"uid" => c["uid"]} end)

      Neuron.Telemetry.emit(
        [:knowledge, :reconciled],
        Map.merge(Neuron.Telemetry.trace_metadata(opts), %{
          entity_id: entity,
          claim_count: length(claims),
          current: current
        })
      )

      text = Enum.join(Map.values(facts), " ")

      with {:ok, context} <- employer_context(facts["employer"], opts),
           {:ok, vector} <- Neuron.Embedding.provider().embed(text <> " " <> context, opts) do
        projection = Map.take(facts, ~w(name description industry title email profile_url body))

        projection =
          Enum.reduce(~w(employer organization owner), projection, fn key, acc ->
            case facts[key] do
              nil ->
                acc

              domain ->
                Map.put(acc, key, %{
                  "uid" => entity_id("Organization", domain),
                  "dgraph.type" => ["Organization", "Entity"],
                  "domain" => domain(domain)
                })
            end
          end)

        projection =
          case facts["location"] do
            nil ->
              projection

            location ->
              Map.put(projection, "location", %{
                "uid" => id("geography", String.downcase(location)),
                "dgraph.type" => ["Geography", "Entity"],
                "name" => location
              })
          end

        projection =
          Enum.reduce(
            [
              {"requirements", "Requirement"},
              {"capabilities", "Capability"},
              {"clients", "ClientProfile"}
            ],
            projection,
            fn {predicate, type}, acc ->
              values =
                claims
                |> Enum.filter(&(&1["predicate"] == predicate))
                |> Enum.uniq_by(& &1["claim_value"])

              nodes =
                Enum.map(values, fn claim ->
                  %{
                    "uid" => id(String.downcase(type), entity <> claim["claim_value"]),
                    "dgraph.type" => [type, "Entity"],
                    "name" => claim["claim_value"],
                    "description" => claim["claim_value"],
                    "evidence" => [%{"uid" => claim["uid"]}]
                  }
                end)

              if nodes == [], do: acc, else: Map.put(acc, predicate, nodes)
            end
          )

        Neuron.Graph.replace(
          Map.merge(projection, %{
            "uid" => record["uid"],
            "knowledge_json" => Jason.encode!(facts),
            "knowledge_text" => text <> " " <> context,
            Neuron.Embedding.field() => vector,
            "embedding_space" => Neuron.Embedding.space(),
            "current_claims" => refs
          }),
          ~w(current_claims employer organization owner location requirements capabilities clients),
          opts
        )
      end
    end
  end

  defp employer_context(nil, _opts), do: {:ok, ""}

  defp employer_context(domain, opts) do
    with {:ok, %{"records" => records}} <-
           Neuron.Graph.query(
             "query employer($domain: string) { records(func: eq(domain, $domain)) { knowledge_text } }",
             %{"$domain" => domain(domain)},
             opts
           ),
         do: {:ok, Enum.map_join(records, " ", &(&1["knowledge_text"] || ""))}
  end

  def resolve(claims) do
    claims
    |> Enum.group_by(& &1["predicate"])
    |> Map.new(fn {predicate, alternatives} ->
      winner =
        Enum.max_by(alternatives, fn claim ->
          {claim["assertion_kind"] == "user", claim["authority"] || 0.0,
           length(
             Enum.uniq_by(
               Enum.filter(alternatives, &(&1["claim_value"] == claim["claim_value"])),
               & &1["url"]
             )
           ), claim["observed_at"] || "", claim["uid"] || ""}
        end)

      {predicate, winner}
    end)
  end

  def index_document(document, snapshot_id, opts) do
    Neuron.Embedding.provider().chunks(document.markdown)
    |> Enum.with_index()
    |> Neuron.Pipeline.map(
      fn {text, index} ->
        with {:ok, vector} <- Neuron.Embedding.provider().embed(text, opts) do
          Neuron.Graph.upsert(
            %{
              "uid" => id("chunk", snapshot_id <> ":#{index}"),
              "dgraph.type" => ["Evidence", "Entity"],
              "body" => text,
              "url" => document.url,
              "documents" => [%{"uid" => snapshot_id}],
              Neuron.Embedding.field() => vector,
              "embedding_space" => Neuron.Embedding.space()
            },
            opts
          )
        end
      end,
      max_concurrency: Keyword.get(opts, :embedding_concurrency, 2)
    )
    |> Enum.find(:ok, &(&1 != :ok))
  end
end
