defmodule Neuron.CampaignPipeline do
  import Ecto.Query

  @moduledoc "Campaign discovery schedules durable source jobs and selects from shared graph evidence."
  def stages,
    do: [:prepare, :retrieve, :plan_search, :search, :dispatch, :collect, :rank, :draft, :finish]

  def stage(:prepare, campaign, opts) do
    for assertion <- Keyword.get(opts, :assertions, campaign[:assertions] || []) do
      :ok = Neuron.Knowledge.assert_fact(assertion, opts)
    end

    {:ok,
     %{
       campaign: campaign,
       round: 0,
       queries: [],
       urls: [],
       children: [],
       leads: [],
       failures: [],
       started_at: DateTime.utc_now()
     }}
  end

  def stage(:retrieve, data, opts) do
    with {:ok, candidates} <- Neuron.Selection.candidates(data.campaign, opts),
         {:ok, leads} <-
           Neuron.Selection.reserve(data.campaign.campaign_id, opts[:run_id], candidates) do
      # Every campaign makes a search pass, including when existing knowledge matches.
      {:ok, %{data | leads: leads}}
    end
  end

  def stage(:plan_search, data, opts) do
    if exhausted?(data, opts) do
      {:goto, :draft, Map.put(data, :stop_reason, :budget_exhausted)}
    else
      with {:ok, gaps} <- Neuron.Selection.enrichment_candidates(data.campaign, opts),
           {:ok, queries} <-
             Neuron.Structured.generate(
               "campaign_search.eex",
               %{
                 seller: inspect(data.campaign.seller_profile),
                 target: inspect(data.campaign.target_profile),
                 previous_queries: inspect(data.queries),
                 failures: inspect(data.failures),
                 leads: inspect(%{selected: data.leads, candidates_needing_enrichment: gaps})
               },
               &validate_queries/1,
               opts
             ) do
        topic =
          Enum.join(
            data.campaign.target_profile.markets ++
              data.campaign.target_profile.geography ++ data.campaign.target_profile.roles,
            " "
          )

        queries = ["site:linkedin.com #{topic}", "site:x.com #{topic}"] ++ queries
        remaining = Keyword.get(opts, :max_queries, 12) - length(data.queries)

        pending =
          queries
          |> Enum.uniq()
          |> Enum.reject(&(&1 in data.queries))
          |> Enum.take(min(remaining, 4))

        if pending == [],
          do: {:goto, :draft, Map.put(data, :stop_reason, :search_exhausted)},
          else: {:ok, Map.merge(data, %{pending_queries: pending, round: data.round + 1})}
      end
    end
  end

  def stage(:search, data, opts) do
    results =
      Neuron.Pipeline.map(
        data.pending_queries,
        fn query -> {query, Neuron.Search.web(query, opts)} end,
        max_concurrency: Keyword.get(opts, :search_concurrency, 2)
      )

    failures =
      for {query, {:error, reason}} <- results, do: %{query: query, reason: inspect(reason)}

    found = for {_, {:ok, rows}} <- results, row <- rows, do: row

    sources =
      found
      |> Enum.uniq_by(& &1.url)
      |> Enum.filter(&Neuron.ContactPolicy.prospect_source?(&1.url))
      |> Enum.reject(
        &(Neuron.Knowledge.domain(&1.url) == data.campaign.seller_profile.domain or
            &1.url in data.urls)
      )
      |> Enum.take(
        min(
          Keyword.get(opts, :batch_size, 8),
          Keyword.get(opts, :max_pages, 32) - length(data.urls)
        )
      )
      |> Enum.map(&%{id: Ecto.UUID.generate(), source: %{url: &1.url}})

    if found == [] and failures != [] do
      {:error, {:search_unavailable, failures}}
    else
      {:ok,
       Map.merge(data, %{
         pending_children: sources,
         queries: data.queries ++ data.pending_queries,
         failures: data.failures ++ failures
       })}
    end
  end

  def stage(:dispatch, data, opts) do
    repo = Neuron.Persistence.repo()

    with {:ok, _} <-
           repo.transaction(fn ->
             parent = Neuron.FSM.get(opts[:run_id])

             if parent.state != "processing" or parent.version != opts[:transition_version],
               do: repo.rollback(:stale)

             {count, _} =
               repo.update_all(
                 from(m in Neuron.FSM.Machine,
                   where: m.id == ^parent.id and m.version == ^parent.version
                 ),
                 set: [updated_at: DateTime.utc_now()]
               )

             if count != 1, do: repo.rollback(:stale)

             for child <- data.pending_children do
               unless repo.get(Neuron.FSM.Machine, child.id) do
                 {:ok, _} =
                   Neuron.Ingestion.submit(
                     child.source,
                     opts
                     |> Keyword.put(:id, child.id)
                     |> Keyword.put(:parent_run_id, opts[:run_id])
                     |> Keyword.put(:campaign_id, data.campaign.campaign_id)
                   )
               end
             end
           end) do
      {:ok,
       %{
         data
         | children: data.children ++ data.pending_children,
           urls: data.urls ++ Enum.map(data.pending_children, & &1.source.url)
       }}
    end
  end

  def stage(:collect, data, _opts) do
    children = Enum.map(data.pending_children, &Neuron.get_run(&1.id))

    if Enum.any?(children, &(&1.status not in [:complete, :failed, :cancelled])) do
      {:wait, 2}
    else
      failures =
        for child <- children,
            child.status != :complete,
            do: %{run_id: child.id, reason: inspect(child.error)}

      {:ok, %{data | failures: data.failures ++ failures}}
    end
  end

  def stage(:rank, data, opts) do
    with {:ok, candidates} <- Neuron.Selection.candidates(data.campaign, opts),
         {:ok, leads} <-
           Neuron.Selection.reserve(data.campaign.campaign_id, opts[:run_id], candidates) do
      data = %{data | leads: leads}

      cond do
        length(leads) >= data.campaign.lead_count ->
          {:goto, :draft, Map.put(data, :stop_reason, :target_met)}

        exhausted?(data, opts) ->
          {:goto, :draft, Map.put(data, :stop_reason, :budget_exhausted)}

        true ->
          {:goto, :plan_search, data}
      end
    end
  end

  def stage(:draft, %{leads: []} = data, _opts),
    do:
      {:ok,
       Map.put(
         data,
         :summary,
         "No new people met the campaign criteria with a verified professional contact channel."
       )}

  def stage(:draft, data, opts) do
    with {:ok, output} <-
           Neuron.Structured.generate(
             "campaign_outreach.eex",
             %{seller: inspect(data.campaign.seller_profile), leads: inspect(data.leads)},
             &validate_drafts(&1, data.leads),
             opts
           ) do
      {:ok, Map.merge(data, output)}
    end
  end

  def stage(:finish, data, opts) do
    status =
      cond do
        data.leads == [] -> :no_qualified_leads
        length(data.leads) < data.campaign.lead_count -> :partial
        true -> :target_met
      end

    result = %{
      campaign_id: data.campaign.campaign_id,
      campaign_run_id: opts[:run_id],
      status: status,
      target_count: data.campaign.lead_count,
      returned_count: length(data.leads),
      leads: data.leads,
      campaign: data.campaign,
      summary: data.summary,
      stop_reason: data.stop_reason,
      failures: data.failures
    }

    with {:ok, _} <- Neuron.Schemas.validate_campaign_result(result),
         :ok <- persist_result(result, opts) do
      {:ok, result}
    end
  end

  defp persist_result(result, opts) do
    campaign_uid = Neuron.Knowledge.id("campaign", result.campaign_id)

    leads =
      Enum.map(result.leads, fn lead ->
        %{
          "uid" => Neuron.Knowledge.id("selection", result.campaign_run_id <> lead.person_id),
          "dgraph.type" => ["Lead", "Entity"],
          "person" => %{"uid" => lead.person_uid},
          "campaign" => %{"uid" => campaign_uid},
          "email" => lead.email,
          "fit_score" => lead.fit_score,
          "reason" => lead.reason,
          "email_subject" => lead.email_subject,
          "email_body" => lead.email_body,
          "preferred_channel" => lead.preferred_channel,
          "outreach_body" => lead.outreach.body,
          "outreach_subject" => lead.outreach.subject,
          "score_breakdown" => Jason.encode!(lead.score_breakdown),
          "semantic_similarity" => lead.semantic_similarity,
          "contact_channels" =>
            Enum.map(lead.contact_channels, fn channel ->
              %{
                "uid" => Neuron.Knowledge.id("contact", channel.kind <> channel.value),
                "dgraph.type" => ["ContactChannel", "Entity"],
                "channel_kind" => channel.kind,
                "channel_value" => channel.value,
                "sources" =>
                  Enum.map(channel.evidence_urls, fn url ->
                    %{
                      "uid" => Neuron.Knowledge.id("source", Neuron.Knowledge.canonical_url(url)),
                      "url" => url
                    }
                  end)
              }
            end)
        }
      end)

    Neuron.Graph.upsert(
      %{
        "uid" => campaign_uid,
        "dgraph.type" => ["Campaign", "Entity"],
        "name" => result.campaign.seller_profile.name,
        "objective" => result.campaign.seller_profile.offer,
        "leads" => leads
      },
      opts
    )
  end

  defp exhausted?(data, opts) do
    data.round >= Keyword.get(opts, :max_rounds, 3) or
      length(data.queries) >= Keyword.get(opts, :max_queries, 12) or
      length(data.urls) >= Keyword.get(opts, :max_pages, 32) or
      DateTime.diff(DateTime.utc_now(), data.started_at) >=
        Keyword.get(opts, :budget_seconds, 1800)
  end

  defp validate_queries(%{"queries" => queries}) when is_list(queries) do
    if queries != [] and Enum.all?(queries, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, queries},
      else: {:error, :invalid_queries}
  end

  defp validate_queries(_), do: {:error, :expected_queries}

  defp validate_drafts(%{"summary" => summary, "leads" => drafts}, leads)
       when is_binary(summary) and is_list(drafts) do
    ids = Enum.map(leads, & &1.person_id) |> Enum.sort()

    if Enum.all?(drafts, &is_map/1) and Enum.sort(Enum.map(drafts, & &1["person_id"])) == ids do
      indexed = Map.new(drafts, &{&1["person_id"], &1})

      Enum.reduce_while(leads, {:ok, []}, fn lead, {:ok, acc} ->
        case Neuron.Outreach.confirm(Map.fetch!(indexed, lead.person_id), lead) do
          {:ok, enriched} -> {:cont, {:ok, [enriched | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, enriched} -> {:ok, %{summary: summary, leads: Enum.reverse(enriched)}}
        error -> error
      end
    else
      {:error, :drafts_must_cover_exactly_selected_people}
    end
  end

  defp validate_drafts(_, _), do: {:error, :expected_summary_and_leads}
end
