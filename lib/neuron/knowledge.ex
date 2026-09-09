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

  def entity_id("Organization", identity), do: id("org", domain(identity))
  def entity_id(type, identity), do: id(String.downcase(type), canonical_url(identity))

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

    with :ok <- Neuron.Graph.upsert(graph, opts), do: {:ok, snapshot_id}
  end

  def validate_claims(%{"claims" => claims}, document) when is_list(claims) do
    Enum.reduce_while(claims, {:ok, []}, fn attrs, {:ok, acc} ->
      with {:ok, claim} <- Neuron.Contracts.validate(Neuron.Contracts.Claim, attrs),
           true <- claim.source_url == document.url,
           true <- String.contains?(document.markdown, claim.excerpt),
           true <-
             claim.predicate != "email" or
               String.contains?(String.downcase(claim.excerpt), String.downcase(claim.value)),
           true <-
             claim.entity_type == "Organization" or
               String.starts_with?(claim.identity, ["https://", "http://"]) do
        {:cont, {:ok, [Neuron.Contracts.plain(claim) | acc]}}
      else
        error -> {:halt, {:error, {:unsupported_claim, attrs, error}}}
      end
    end)
  end

  def validate_claims(_, _), do: {:error, :expected_claims_array}

  def ingest(claims, document, snapshot_id, opts) do
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
              "observed_at" => DateTime.to_iso8601(document.published_at || document.fetched_at),
              "authority" => authority(claim, document),
              "assertion_kind" => "observed",
              "documents" => [%{"uid" => snapshot_id}],
              "subject" => %{"uid" => entity}
            }
          ]
        }
        |> Map.put(
          if(claim.entity_type == "Organization", do: "domain", else: "profile_url"),
          if(claim.entity_type == "Organization",
            do: domain(claim.identity),
            else: canonical_url(claim.identity)
          )
        )
      end)

    with :ok <- Neuron.Graph.upsert(nodes, opts) do
      Enum.map(claims, &entity_id(&1.entity_type, &1.identity))
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn entity, :ok ->
        case reconcile(entity, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp authority(claim, document) do
    host = domain(document.url)

    cond do
      host == domain(claim.identity) -> 1.0
      host in ["linkedin.com", "x.com", "twitter.com"] -> 0.8
      true -> 0.5
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

      Neuron.Graph.upsert(
        %{
          "uid" => record["uid"],
          "knowledge_json" => Jason.encode!(facts),
          "knowledge_text" => Enum.join(Map.values(facts), " "),
          "current_claims" => refs
        },
        opts
      )
    end
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
    document.markdown
    |> String.graphemes()
    |> Enum.chunk_every(2000)
    |> Enum.with_index()
    |> Neuron.Pipeline.map(
      fn {chars, index} ->
        text = Enum.join(chars)

        with {:ok, vector} <- Neuron.Embedding.provider().embed(text, opts) do
          Neuron.Graph.upsert(
            %{
              "uid" => id("chunk", snapshot_id <> ":#{index}"),
              "dgraph.type" => ["Evidence", "Entity"],
              "body" => text,
              "url" => document.url,
              "documents" => [%{"uid" => snapshot_id}],
              "embedding" => vector
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
