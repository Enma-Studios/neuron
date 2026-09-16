defmodule Neuron.Selection.Reservation do
  use Ecto.Schema
  @primary_key false
  schema "neuron_selections" do
    field(:campaign_id, :string, primary_key: true)
    field(:person_id, :string, primary_key: true)
    field(:run_id, :string)
    field(:delivered, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Neuron.Selection do
  @moduledoc "Evidence-qualified hybrid matching and campaign-scoped delivery reservations."
  import Ecto.Query
  alias Neuron.Selection.Reservation
  @weights %{market: 0.35, role: 0.20, geography: 0.15, evidence: 0.15, freshness: 0.15}
  @personal ~w(gmail.com yahoo.com outlook.com hotmail.com proton.me protonmail.com icloud.com)
  @generic ~w(info hello contact sales support office admin enquiries inquiries team careers press)

  @checks ~w(name employer seller role geography exclusion size industry threshold)a
  @gates ~w(size industry)a

  def enrichment_candidates(campaign, opts) do
    query = query_terms(campaign.target_profile)

    Neuron.Graph.query(
      "query gaps($q: string) { candidates(func: anyoftext(knowledge_text, $q), first: 30) @filter(type(Person)) { profile_url knowledge_json assertions { predicate claim_value url } } }",
      %{"$q" => query},
      opts
    )
  end

  def candidates(campaign, opts) do
    query = query_terms(campaign.target_profile)

    with {:ok, vector} <-
           Neuron.Embedding.provider().embed(
             campaign.seller_profile.offer <> " " <> query,
             Keyword.put(opts, :embedding_purpose, :query)
           ),
         {:ok, lexical} <-
           Neuron.Graph.query(
             "query candidates($q: string, $space: string) { results(func: anyoftext(knowledge_text, $q), first: 200) @filter(type(Person) AND eq(embedding_space, $space)) { uid external_id profile_url #{Neuron.Embedding.field()} assertions { uid predicate claim_value excerpt url observed_at authority assertion_kind } employer { name description industry knowledge_json } } }",
             %{"$q" => query, "$space" => Neuron.Embedding.space()},
             opts
           ),
         {:ok, semantic} <-
           Neuron.Graph.query(
             "query candidates($v: float32vector, $space: string) { results(func: similar_to(#{Neuron.Embedding.field()}, 200, $v)) @filter(type(Person) AND eq(embedding_space, $space)) { uid external_id profile_url #{Neuron.Embedding.field()} assertions { uid predicate claim_value excerpt url observed_at authority assertion_kind } employer { name description industry knowledge_json } } }",
             %{"$v" => vector, "$space" => Neuron.Embedding.space()},
             opts
           ) do
      {ranked, selection} =
        Neuron.GraphSearch.fuse(lexical, semantic) |> select(campaign, vector, opts)

      {:ok, ranked, selection}
    end
  end

  @doc """
  Rank `records` for `campaign` and account for every one that was not
  ranked. A run that returns no leads is otherwise the same to a host
  whether nobody was considered or everybody was rejected.

  `rejected_by` counts, per check, the candidates that failed it; one
  candidate can fail several. People who matched but had no observed contact
  channel are `withheld_contact`, so a caller can tell "no companies matched"
  from "companies matched, no contact channel".
  """
  def select(records, campaign, vector, opts \\ []) do
    results = Enum.map(records, &evaluate(&1, campaign, vector, opts))
    rejections = for {:rejected, checks} <- results, do: checks

    # Counts say a check failed; this says for whom, so a host can tell a
    # correct rejection from a matching bug without reading the graph.
    rejected_people =
      for {record, {:rejected, checks}} <- Enum.zip(records, results) do
        facts =
          Neuron.Knowledge.resolve(record["assertions"] || [])
          |> Map.new(fn {key, claim} -> {key, claim["claim_value"]} end)

        %{
          person_id: record["external_id"],
          name: facts["name"],
          title: facts["title"],
          employer: facts["employer"],
          checks: checks
        }
      end

    ranked =
      for({:lead, lead} <- results, do: lead)
      |> Enum.sort_by(&{-&1.contact_priority, -&1.fit_score, &1.person_id})

    {ranked,
     %{
       considered: length(records),
       ranked: length(ranked),
       withheld_contact: Enum.count(results, &(&1 == :no_contact_channel)),
       rejected: length(rejections),
       rejected_people: rejected_people,
       # Candidates a gate let through because their organization did not
       # say: no observed size, or no industry or description.
       unknown_by:
         Map.new(@gates, fn gate ->
           {gate, Enum.count(records, &(gate(gate, &1, campaign.target_profile) == :unknown))}
         end),
       rejected_by:
         Map.new(@checks, fn check -> {check, Enum.count(rejections, &(check in &1))} end)
     }}
  end

  @doc """
  Score one candidate: a lead map, `nil` when the person does not match the
  campaign, or `:no_contact_channel` when they match but have no observed
  contact channel and `require_contact_channel` is on.

  `require_contact_channel` defaults to `true`, which is the behaviour every
  existing caller gets. Set it to `false` when the caller resolves contacts
  itself: the person is then returned with `observed_email: nil` and no
  channels, and everything else about the lead is unchanged.
  """
  def score(record, campaign, vector, opts \\ []) do
    case evaluate(record, campaign, vector, opts) do
      {:lead, lead} -> lead
      {:rejected, _checks} -> nil
      :no_contact_channel -> :no_contact_channel
    end
  end

  defp evaluate(record, campaign, vector, opts) do
    claims = Neuron.Knowledge.resolve(record["assertions"] || [])
    facts = Map.new(claims, fn {key, c} -> {key, c["claim_value"]} end)
    target = campaign.target_profile
    email = String.downcase(facts["email"] || "")
    employer = Neuron.Knowledge.domain(facts["employer"] || "")
    title = facts["title"] || ""
    location = facts["location"] || ""
    text = Enum.join(Map.values(facts), " ")
    # Titles are the concrete job titles the campaign's roles were expanded
    # into. Roles are usually categories ("technology leaders") that no
    # title contains, so without them nobody matched at all.
    role = match_words(target.roles ++ Map.get(target, :titles, []), title)
    geography = match_terms(target.geography, location)
    employment = observed_claim(record, "employer", facts["employer"])
    email_claim = observed_claim(record, "email", facts["email"])

    verified_email =
      company_email?(email, employer) && email_claim &&
        String.contains?(String.downcase(email_claim["excerpt"]), email)

    social_channels = professional_channels(record, claims)

    email_channels =
      if verified_email,
        do: [%{kind: "email", value: email, evidence_urls: [email_claim["url"]]}],
        else: []

    channels = email_channels ++ social_channels

    # Matching the campaign and having an observed way to reach the person
    # are two different questions, and the host answers the second one
    # itself through its contact provider waterfall.
    failed =
      [
        name: !facts["name"],
        employer: employer == "" or !employment or (employment["authority"] || 0) < 0.8,
        seller: employer != "" and employer == campaign.seller_profile.domain,
        role: role == 0,
        geography: geography == 0,
        exclusion: Enum.any?(target.exclusions, &contains?(exclusion_text(record, text), &1)),
        size: gate(:size, record, target) == :fail,
        industry: gate(:industry, record, target) == :fail
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Keyword.keys()

    require_channel? = Keyword.get(opts, :require_contact_channel, true)

    cond do
      failed != [] ->
        {:rejected, failed}

      channels == [] and require_channel? ->
        :no_contact_channel

      true ->
        cosine = cosine(vector, record[Neuron.Embedding.field()])
        market = 0.5 * match_terms(target.markets, text) + 0.5 * max(cosine, 0.0)

        observed =
          Enum.map(Map.values(claims), & &1["observed_at"])
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end)

        components = %{
          market: market,
          role: role,
          geography: geography,
          evidence:
            Enum.sum(Enum.map(Map.values(claims), &(&1["authority"] || 0.0))) /
              max(map_size(claims), 1),
          freshness: freshness(observed, Keyword.get(opts, :now, DateTime.utc_now()))
        }

        weights =
          Keyword.get(
            opts,
            :weights,
            Application.get_env(:neuron, :selection, [])[:weights] || @weights
          )

        score =
          Enum.sum(
            Enum.map(weights, fn {key, weight} -> Map.fetch!(components, key) * weight end)
          )

        threshold = Keyword.get(opts, :selection_threshold, 0.5)

        if score >= threshold do
          observed_email = if verified_email, do: email, else: nil

          result = %{
            person_id: record["external_id"],
            person_uid: record["uid"],
            person_name: facts["name"],
            title: title,
            email: observed_email,
            observed_email: observed_email,
            contact_channels: channels,
            preferred_channel: (channels != [] && hd(channels).kind) || nil,
            contact_priority:
              (channels != [] && 1.0 / (1 + channel_rank(hd(channels).kind))) || 0.0,
            organization: employer,
            location: location,
            fit_score: score,
            score_breakdown: components,
            semantic_similarity: cosine,
            evidence: Map.values(claims),
            evidence_urls: Enum.map(Map.values(claims), & &1["url"]) |> Enum.uniq(),
            observed_at: observed
          }

          Neuron.Telemetry.emit(
            [:lead, :ranked],
            Map.merge(Neuron.Telemetry.trace_metadata(opts), result)
          )

          {:lead, result}
        else
          {:rejected, [:threshold]}
        end
    end
  end

  def company_email?(email, employer) do
    case String.split(email, "@") do
      [local, host] ->
        local != "" && local not in @generic && host not in @personal &&
          (host == employer || String.ends_with?(host, "." <> employer))

      _ ->
        false
    end
  end

  defp professional_channels(record, claims) do
    urls = [record["profile_url"], get_in(claims, ["profile_url", "claim_value"])]

    urls
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, ["https://", "http://"])))
    |> Enum.filter(&Neuron.ContactPolicy.prospect_source?/1)
    |> Enum.uniq()
    |> Enum.map(fn url ->
      profile_claim = observed_claim(record, "profile_url", url)

      if is_nil(profile_claim), do: nil, else: {url, profile_claim}
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {url, profile_claim} ->
      host = Neuron.Knowledge.domain(url)

      kind =
        cond do
          host == "linkedin.com" -> "linkedin"
          host in ["x.com", "twitter.com"] -> "x"
          true -> "social"
        end

      %{
        kind: kind,
        value: url,
        evidence_urls: [profile_claim["url"]]
      }
    end)
    |> Enum.sort_by(&channel_rank(&1.kind))
  end

  def channel_rank(kind) do
    order =
      Application.get_env(:neuron, :selection, [])[:channel_order] || ~w(email linkedin x social)

    Enum.find_index(order, &(&1 == kind)) || length(order)
  end

  defp observed_claim(record, predicate, value) do
    Enum.find(record["assertions"] || [], fn claim ->
      claim["predicate"] == predicate and claim["claim_value"] == value and
        claim["assertion_kind"] != "user" and
        String.starts_with?(claim["url"] || "", ["http://", "https://"])
    end)
  end

  def cosine(left, right) when is_binary(right) do
    case Jason.decode(right) do
      {:ok, vector} -> cosine(left, vector)
      _ -> 0.0
    end
  end

  def cosine(left, right)
      when is_list(left) and is_list(right) and length(left) == length(right) do
    norm =
      :math.sqrt(Enum.sum(Enum.map(left, &(&1 * &1)))) *
        :math.sqrt(Enum.sum(Enum.map(right, &(&1 * &1))))

    if norm == 0,
      do: 0.0,
      else: Enum.zip_with(left, right, &(&1 * &2)) |> Enum.sum() |> Kernel./(norm)
  end

  def cosine(_, _), do: 0.0
  defp match_terms([], _), do: 1.0

  defp match_terms(terms, text),
    do: if(Enum.any?(terms, &contains?(text, &1)), do: 1.0, else: 0.0)

  # An exclusion usually describes the company ("security vendors"), which a
  # person's own facts never say, so the employer organization is read too.
  defp exclusion_text(record, text) do
    record["employer"]
    |> List.wrap()
    |> Enum.flat_map(&[&1["name"], &1["description"], &1["industry"]])
    |> Enum.reject(&is_nil/1)
    |> then(&Enum.join([text | &1], " "))
  end

  # Organization gates read the employer, so a campaign scoped to companies
  # of 20 to 300 software people stops ranking travel groups and analysts.
  # Neither is ever inferred: an organization that did not say passes, and
  # is counted as unknown.
  defp gate(:size, record, target) do
    with %{} = range <- Map.get(target, :company_size),
         [_ | _] = counts <- employee_counts(organization_facts(record)["employee_count"]) do
      if (range[:min] && Enum.max(counts) < range[:min]) ||
           (range[:max] && Enum.min(counts) > range[:max]),
         do: :fail,
         else: :pass
    else
      nil -> :pass
      [] -> :unknown
    end
  end

  defp gate(:industry, record, target) do
    organization = organization(record)
    facts = organization_facts(record)

    text =
      [
        organization["industry"] || facts["industry"],
        organization["description"] || facts["description"]
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    cond do
      Map.get(target, :industries, []) == [] -> :pass
      text == "" -> :unknown
      Enum.any?(target.industries, &word?(text, &1)) -> :pass
      true -> :fail
    end
  end

  defp organization(record), do: record["employer"] |> List.wrap() |> List.first() || %{}

  defp organization_facts(record) do
    case Jason.decode(organization(record)["knowledge_json"] || "") do
      {:ok, %{} = facts} -> facts
      _ -> %{}
    end
  end

  # "120", "51-200" and "5,000+" all state a size; anything without a
  # number does not.
  defp employee_counts(value) when is_binary(value) do
    for [digits] <- Regex.scan(~r/\d[\d,]*/, value),
        {count, _} = Integer.parse(String.replace(digits, ",", "")),
        do: count
  end

  defp employee_counts(_), do: []

  defp match_words([], _), do: 1.0

  defp match_words(terms, text),
    do: if(Enum.any?(terms, &word?(text, &1)), do: 1.0, else: 0.0)

  # A title must hold the term as whole words: "Director" contains the
  # letters of "CTO" and is not one.
  defp word?(text, term),
    do: Regex.match?(~r/(?<![\p{L}\p{N}])#{Regex.escape(term)}(?![\p{L}\p{N}])/iu, text)

  defp query_terms(target),
    do: Enum.join(target.markets ++ target.roles ++ Map.get(target, :titles, []), " ")

  defp contains?(text, term), do: String.contains?(String.downcase(text), String.downcase(term))
  defp freshness(nil, _), do: 0.0

  defp freshness(timestamp, now) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, date, _} -> :math.pow(0.5, max(DateTime.diff(now, date, :second), 0) / (90 * 86400))
      _ -> 0.0
    end
  end

  def reserve(campaign_id, run_id, candidates) do
    repo = Neuron.Persistence.repo()

    repo.transaction(fn ->
      machine = Neuron.FSM.get(run_id)
      if machine.state in ["cancelled", "failed"], do: repo.rollback(:run_not_active)
      # Touch the parent under its version to serialize reservation against cancellation.
      {count, _} =
        repo.update_all(
          from(m in Neuron.FSM.Machine, where: m.id == ^run_id and m.version == ^machine.version),
          set: [updated_at: DateTime.utc_now()]
        )

      if count != 1, do: repo.rollback(:stale)

      Enum.filter(candidates, fn lead ->
        repo.insert!(
          %Reservation{campaign_id: campaign_id, run_id: run_id, person_id: lead.person_id},
          on_conflict: :nothing
        )

        repo.exists?(
          from(r in Reservation,
            where:
              r.campaign_id == ^campaign_id and r.person_id == ^lead.person_id and
                r.run_id == ^run_id
          )
        )
      end)
    end)
  end

  def release(run_id) do
    Neuron.Persistence.repo().delete_all(
      from(r in Reservation, where: r.run_id == ^run_id and not r.delivered)
    )

    :ok
  end

  def delivered(run_id) do
    Neuron.Persistence.repo().update_all(from(r in Reservation, where: r.run_id == ^run_id),
      set: [delivered: true]
    )

    :ok
  end

  def delivered(run_id, person_ids) do
    Neuron.Persistence.repo().delete_all(
      from(r in Reservation,
        where: r.run_id == ^run_id and not r.delivered and r.person_id not in ^person_ids
      )
    )

    delivered(run_id)
  end
end
