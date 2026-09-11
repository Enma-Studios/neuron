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
       searches: [],
       urls: [],
       children: [],
       leads: [],
       failures: [],
       started_at: DateTime.utc_now()
     }}
  end

  def stage(:retrieve, data, opts) do
    with {:ok, candidates, withheld} <- Neuron.Selection.candidates(data.campaign, opts),
         {:ok, leads} <-
           Neuron.Selection.reserve(data.campaign.campaign_id, opts[:run_id], candidates) do
      # Every campaign makes a search pass, including when existing knowledge matches.
      {:ok, Map.merge(data, %{leads: leads, withheld_contact: withheld})}
    end
  end

  def stage(:plan_search, data, opts) do
    if exhausted?(data, opts) do
      {:goto, :draft, Map.put(data, :stop_reason, :budget_exhausted)}
    else
      enabled = Neuron.Search.engines(opts)

      with {:ok, gaps} <- Neuron.Selection.enrichment_candidates(data.campaign, opts),
           {:ok, searches} <-
             Neuron.Structured.generate(
               "campaign_search.eex",
               %{
                 seller: inspect(data.campaign.seller_profile),
                 target: inspect(data.campaign.target_profile),
                 previous_searches: inspect(data.searches),
                 failures: inspect(data.failures),
                 leads: inspect(%{selected: data.leads, candidates_needing_enrichment: gaps}),
                 engines: Enum.map_join(enabled, ", ", &Neuron.Search.engine_id(&1))
               },
               &Neuron.Search.validate_searches(&1, enabled),
               opts
             ) do
        searches = Enum.reject(searches, &(&1 in data.searches))
        remaining = Keyword.get(opts, :max_queries, 50) - length(data.searches)

        # Balanced after truncation, or the coverage queries are the ones
        # the budget drops and the round asks one engine again.
        pending =
          searches
          |> Enum.uniq()
          |> Enum.take(min(remaining, Keyword.get(opts, :searches_per_round, 8)))
          |> Neuron.Search.balance(enabled)

        if pending == [],
          do: {:goto, :draft, Map.put(data, :stop_reason, :search_exhausted)},
          else: {:ok, Map.merge(data, %{pending_searches: pending, round: data.round + 1})}
      end
    end
  end

  def stage(:search, data, opts) do
    search_opts = Keyword.put(opts, :seller_domain, data.campaign.seller_profile.domain)

    case Neuron.Search.orchestrate(data.pending_searches, search_opts) do
      {:ok, found, failures} ->
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
              Keyword.get(opts, :max_pages, 96) - length(data.urls)
            )
          )
          |> Enum.map(&%{id: Ecto.UUID.generate(), source: %{url: &1.url}})

        {:ok,
         Map.merge(data, %{
           pending_children: sources,
           searches: data.searches ++ data.pending_searches,
           failures: data.failures ++ Enum.map(failures, &search_failure/1)
         })}

      {:error, {:search_unavailable, reason: {:all_searches_failed, failures}}} ->
        {:error, {:search_unavailable, Enum.map(failures, &search_failure/1)}}

      {:error, {:search_unavailable, reason: reason}} ->
        {:error, {:search_unavailable, [%{query: "(search)", reason: inspect(reason)}]}}
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
    # Reconciled rather than read: a child whose worker was discarded would
    # otherwise sit in `processing` forever and this stage would snooze
    # against it until the run's budget ran out.
    children = Enum.map(data.pending_children, &Neuron.reconcile_run(&1.id))

    if Enum.any?(children, &(&1.status not in [:complete, :failed, :cancelled])) do
      {:wait, 2}
    else
      failures =
        for child <- children,
            child.status != :complete,
            do: %{
              run_id: child.id,
              reason: inspect(child.error),
              kind: Neuron.Usage.error_class(child.error) || :child_failed
            }

      # A child that could not browse is a configuration fault, not a source
      # that happened not to work. Every child in a batch failing that way
      # means the run cannot discover anything, and a run that says it found
      # nothing is a worse answer than one that says it was never able to
      # look.
      if children != [] and length(failures) == length(children) and
           Enum.all?(failures, &(&1.reason =~ "browser_use_not_configured")) do
        {:error, :browser_use_not_configured}
      else
        {:ok, %{data | failures: data.failures ++ failures}}
      end
    end
  end

  def stage(:rank, data, opts) do
    with {:ok, candidates, withheld} <- Neuron.Selection.candidates(data.campaign, opts),
         {:ok, leads} <-
           Neuron.Selection.reserve(data.campaign.campaign_id, opts[:run_id], candidates) do
      data = Map.merge(data, %{leads: leads, withheld_contact: withheld})

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

  # Zero leads has two causes and the host needs to know which. Nothing
  # matched is a targeting problem; matched-but-unreachable is a contact
  # problem the host can solve itself with `require_contact_channel: false`.
  def stage(:draft, %{leads: []} = data, _opts) do
    summary =
      if Map.get(data, :withheld_contact, 0) > 0 do
        "Companies matched the campaign criteria, but no contact channel was observed for any candidate."
      else
        "No companies matched the campaign criteria."
      end

    {:ok, Map.put(data, :summary, summary)}
  end

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
          "outreach_body" => lead.outreach && lead.outreach.body,
          "outreach_subject" => lead.outreach && lead.outreach.subject,
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
    data.round >= Keyword.get(opts, :max_rounds, 12) or
      length(data.searches) >= Keyword.get(opts, :max_queries, 50) or
      length(data.urls) >= Keyword.get(opts, :max_pages, 96) or
      DateTime.diff(DateTime.utc_now(), data.started_at) >=
        Keyword.get(opts, :budget_seconds, 7200)
  end

  defp search_failure(%{engine: engine, query: query, reason: reason} = failure) do
    %{
      engine: Neuron.Search.engine_id(engine),
      kind: failure[:kind] || :unknown,
      query: "#{Neuron.Search.engine_id(engine)}: #{query}",
      reason: to_string(reason)
    }
  end

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
