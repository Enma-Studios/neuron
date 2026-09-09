defmodule Neuron.Campaign do
  @moduledoc "Campaign intake and off-agent lead-count orchestration."

  @questions [
    %{
      key: :organization,
      label: "Organization",
      prompt: "Which organization or domain is this campaign for?",
      required: true
    },
    %{
      key: :field,
      label: "Field",
      prompt: "What field or market does the organization operate in?",
      required: true
    },
    %{
      key: :offer,
      label: "Offer",
      prompt: "What are you offering and why should a prospect care?",
      required: true
    },
    %{
      key: :target_roles,
      label: "Target roles",
      prompt: "Which people or decision-maker roles should be contacted?",
      required: true
    },
    %{
      key: :target_organizations,
      label: "Target organizations",
      prompt: "Which organization types, industries, or account traits are in scope?",
      required: false
    },
    %{
      key: :geography,
      label: "Geography",
      prompt: "Which countries, regions, or markets are preferred?",
      required: false
    },
    %{
      key: :exclusions,
      label: "Exclusions",
      prompt:
        "Which people, organizations, branches, sources, or contact types must be excluded?",
      required: false
    },
    %{
      key: :lead_count,
      label: "Lead count",
      prompt: "How many unique leads should the campaign return?",
      required: true
    }
  ]

  @doc "The bounded campaign intake questionnaire (never more than eight questions)."
  def questions, do: @questions

  @doc "Return a prompt-ready questionnaire for a UI or conversational agent."
  def question_prompt(partial \\ %{}) do
    missing = missing_questions(partial)

    "Please answer these campaign questions. Answer only what is still missing:\n" <>
      Enum.map_join(missing, "\n", fn q -> "#{q.label}: #{q.prompt}" end)
  end

  @doc "Use supplied answers first; if a URL is present, scrape it to fill missing answers."
  def intake(input, opts \\ []) when is_map(input) do
    answers = normalize_keys(input[:answers] || input["answers"] || input)
    url = answers[:url] || answers[:website] || input[:url] || input["url"]

    if answers[:action] in [:different_campaign, "different_campaign", :start_over, "start_over"] do
      {:needs_input, %{questions: questions(), partial: %{}, reason: :new_campaign_requested}}
    else
      intake_answers(answers, url, opts)
    end
  end

  @doc "Approve one or more URL-derived campaign proposals before running them."
  def approve(%{campaigns: campaigns}, selection \\ :all) when is_list(campaigns) do
    selected = select_campaigns(campaigns, selection)

    normalized =
      selected
      |> Enum.map(&normalize_campaign/1)
      |> Enum.reduce_while([], fn
        {:ok, campaign}, acc -> {:cont, [campaign | acc]}
        {:needs_input, details}, _acc -> {:halt, {:needs_input, details}}
      end)

    case normalized do
      {:needs_input, details} -> {:needs_input, details}
      campaigns -> {:ok, Enum.reverse(campaigns)}
    end
  end

  @doc "Run several approved campaigns, keeping each target counter independent."
  def run_many(campaigns, opts \\ []) when is_list(campaigns) do
    base = opts[:run_id] || "campaign-batch-#{System.unique_integer([:positive])}"

    Enum.with_index(campaigns, 1)
    |> Enum.map(fn {campaign, index} ->
      run(campaign, Keyword.put(opts, :run_id, "#{base}-#{index}"))
    end)
  end

  defp intake_answers(answers, url, opts) do
    with {:ok, scraped} <- scrape_answers(url, opts),
         merged <- Map.merge(scraped, answers),
         :ok <- approve_if_needed(merged),
         merged <- merge_approved_campaign(merged),
         {:ok, campaign} <- normalize_campaign(merged) do
      {:ok, campaign}
    else
      {:approval_required, details} ->
        {:approval_required, details}

      {:needs_input, details} ->
        {:needs_input, details}

      {:error, _reason} when is_binary(url) ->
        {:needs_input, %{questions: questions(), partial: answers, reason: :url_unavailable}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp approve_if_needed(%{candidate_campaigns: campaigns} = merged) when length(campaigns) > 1 do
    if merged[:approved_campaigns] || merged[:campaign_approval] do
      :ok
    else
      {:approval_required,
       %{
         campaigns: campaigns,
         prompt:
           "Multiple campaign briefs were found. Approve one or more before research, or reply with action=different_campaign.",
         reason: :multiple_campaigns
       }}
    end
  end

  defp approve_if_needed(_), do: :ok

  defp merge_approved_campaign(%{candidate_campaigns: [candidate]} = merged),
    do: merge_nonblank(candidate, Map.drop(merged, [:candidate_campaigns]))

  defp merge_approved_campaign(
         %{candidate_campaigns: campaigns, approved_campaigns: selection} = merged
       ) do
    case select_campaigns(campaigns, selection) do
      [candidate] ->
        merge_nonblank(candidate, Map.drop(merged, [:candidate_campaigns, :approved_campaigns]))

      _ ->
        merged
    end
  end

  defp merge_approved_campaign(merged), do: merged

  defp merge_nonblank(base, overrides) do
    Enum.reduce(overrides, base, fn {key, value}, acc ->
      if blank?(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp select_campaigns(campaigns, :all), do: campaigns
  defp select_campaigns(campaigns, "all"), do: campaigns

  defp select_campaigns(campaigns, selection) when is_list(selection) do
    Enum.map(selection, fn
      index when is_integer(index) -> Enum.at(campaigns, index)
      selected when is_map(selected) -> selected
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp select_campaigns(campaigns, index) when is_integer(index),
    do: List.wrap(Enum.at(campaigns, index))

  defp select_campaigns(_campaigns, _), do: []

  @doc "Run research repeatedly until the off-agent unique lead target is met."
  def run(campaign, opts \\ []) when is_map(campaign) do
    with {:ok, campaign} <- normalize_campaign(campaign) do
      target = max(integer(campaign[:lead_count] || campaign["lead_count"], 1), 1)
      max_attempts = max(integer(opts[:max_attempts], 3), 1)
      campaign_run_id = opts[:run_id] || "campaign-#{System.unique_integer([:positive])}"
      collect(campaign, opts, campaign_run_id, target, max_attempts, 1, %{}, [])
    end
  end

  defp collect(campaign, _opts, campaign_run_id, target, _max, _attempt, leads, failures)
       when map_size(leads) >= target do
    Neuron.Telemetry.emit([:campaign, :target], %{
      run_id: campaign_run_id,
      target_count: target,
      unique_leads: map_size(leads),
      status: :target_met
    })

    campaign_outbox_id = persist_campaign(campaign, campaign_run_id, Map.values(leads), failures)

    {:ok,
     %{
       status: :target_met,
       campaign_run_id: campaign_run_id,
       campaign: campaign,
       target_count: target,
       leads: Map.values(leads),
       failures: failures,
       campaign_outbox_id: campaign_outbox_id
     }}
  end

  defp collect(campaign, opts, campaign_run_id, target, max_attempts, attempt, leads, failures)
       when attempt <= max_attempts do
    run_id = "#{campaign_run_id}-attempt-#{attempt}"

    Neuron.Telemetry.emit([:campaign, :attempt], %{
      run_id: campaign_run_id,
      attempt_run_id: run_id,
      attempt: attempt,
      target_count: target,
      unique_leads: map_size(leads)
    })

    research_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:parent_run_id, campaign_run_id)
      |> Keyword.put(:campaign_attempt, attempt)

    case Neuron.Research.run(domain(campaign), fit_profile(campaign), research_opts) do
      {:ok, result} ->
        fresh =
          Enum.reduce(result.leads || [], leads, fn lead, acc ->
            Map.put_new(acc, lead_key(lead), lead)
          end)

        collect(
          campaign,
          opts,
          campaign_run_id,
          target,
          max_attempts,
          attempt + 1,
          fresh,
          failures
        )

      {:error, reason} ->
        collect(campaign, opts, campaign_run_id, target, max_attempts, attempt + 1, leads, [
          %{attempt: attempt, error: reason} | failures
        ])
    end
  end

  defp collect(campaign, _opts, campaign_run_id, target, _max, _attempt, leads, failures) do
    Neuron.Telemetry.emit([:campaign, :target], %{
      run_id: campaign_run_id,
      target_count: target,
      unique_leads: map_size(leads),
      status: :failed
    })

    campaign_outbox_id = persist_campaign(campaign, campaign_run_id, Map.values(leads), failures)

    {:error,
     {:lead_target_unmet,
      %{
        campaign_run_id: campaign_run_id,
        campaign: campaign,
        target_count: target,
        leads: Map.values(leads),
        failures: Enum.reverse(failures),
        campaign_outbox_id: campaign_outbox_id
      }}}
  end

  defp persist_campaign(campaign, run_id, leads, failures) do
    domain = domain(campaign)
    lead_uids = Enum.map(leads, &%{"uid" => blank_uid("lead", domain <> lead_key(&1))})

    graph =
      %{
        "uid" => blank_uid("campaign", run_id),
        "dgraph.type" => ["Campaign", "Entity"],
        "name" => to_string(campaign[:name] || campaign[:organization] || domain),
        "objective" => to_string(campaign[:offer] || "Lead generation"),
        "target_people" => lead_uids,
        "leads" => lead_uids,
        "target_geographies" =>
          Enum.map(
            List.wrap(campaign[:geography]),
            &%{"name" => to_string(&1), "dgraph.type" => ["Geography", "Entity"]}
          ),
        "sources" => []
      }

    {:ok, outbox_id} =
      Neuron.Outbox.enqueue(run_id, :campaign, %{graph: graph, failures: failures})

    outbox_id
  end

  defp blank_uid(kind, value),
    do:
      "_:#{kind}-#{Base.encode16(:crypto.hash(:sha256, value), case: :lower) |> binary_part(0, 20)}"

  defp scrape_answers(nil, _opts), do: {:ok, %{}}
  defp scrape_answers("", _opts), do: {:ok, %{}}

  defp scrape_answers(url, opts) when is_binary(url) do
    with {:ok, page} <- Neuron.Browser.fetch(url, opts),
         html when is_binary(html) <- page[:html] || page["html"],
         {:ok, snapshot} <-
           Neuron.Snapshot.from_html(html, %{url: url, title: page[:title], run_id: opts[:run_id]}),
         {:ok, prompt} <-
           Neuron.Prompt.render_file(
             "campaign_intake.eex",
             %{url: url, evidence: String.slice(snapshot.markdown, 0, 16_000)},
             opts
           ),
         {:ok, response} <-
           model(opts).complete(
             [
               %{role: "system", content: "Extract campaign facts as JSON only."},
               %{role: "user", content: prompt}
             ],
             Keyword.put(opts, :task_id, "campaign:intake")
           ),
         {:ok, parsed} <- decode(response) do
      parsed = normalize_keys(parsed)
      proposals = List.wrap(parsed[:campaigns])

      {:ok,
       Map.drop(parsed, [:campaigns])
       |> Map.put(:candidate_campaigns, proposals)
       |> Map.put(:url, url)}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :page_without_html}
    end
  end

  defp normalize_campaign(values) do
    values = normalize_keys(values)

    values =
      if blank?(values[:organization]) and not blank?(values[:domain]),
        do: Map.put(values, :organization, values[:domain]),
        else: values

    missing = missing_questions(values)

    if missing == [] do
      organization = values[:organization] || values[:domain]
      domain = values[:domain] || domain_from_url(values[:url]) || hostname(organization)

      if is_binary(domain) and domain != "" do
        {:ok, Map.merge(values, %{domain: domain, fit_profile: fit_profile(values)})}
      else
        {:needs_input,
         %{
           questions: [Enum.find(@questions, &(&1.key == :organization))],
           partial: values,
           reason: :organization_domain_required
         }}
      end
    else
      {:needs_input, %{questions: missing, partial: values, reason: :missing_campaign_details}}
    end
  end

  defp missing_questions(values) do
    Enum.filter(@questions, fn q ->
      q.required and not satisfied_by_profile?(q.key, values) and
        blank?(values[q.key] || values[Atom.to_string(q.key)])
    end)
  end

  defp satisfied_by_profile?(key, values) when key in [:field, :offer, :target_roles],
    do: is_map(values[:fit_profile])

  defp satisfied_by_profile?(_key, _values), do: false

  defp fit_profile(values) do
    values[:fit_profile] ||
      %{
        requirements:
          Enum.map(List.wrap(values[:field]), &%{category: "field", description: to_string(&1)}) ++
            Enum.map(
              List.wrap(values[:target_roles]),
              &%{category: "target_role", description: to_string(&1)}
            ),
        target_organizations: List.wrap(values[:target_organizations]),
        preferred_geographies: List.wrap(values[:geography] || values[:preferred_geographies]),
        exclusions: List.wrap(values[:exclusions]),
        offer: values[:offer],
        threshold: values[:threshold] || 0.0
      }
  end

  defp domain(campaign),
    do:
      campaign[:domain] || campaign["domain"] ||
        hostname(campaign[:organization] || campaign["organization"])

  defp lead_key(lead) do
    String.downcase(
      to_string(
        lead["email"] || lead[:email] || lead["profile_url"] || lead[:profile_url] ||
          lead["person_name"] || lead[:person_name] || inspect(lead)
      )
    )
  end

  defp normalize_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {if(is_binary(k), do: String.to_atom(k), else: k), v} end)

  defp normalize_keys(other), do: other

  defp domain_from_url(url) when is_binary(url), do: hostname(url)
  defp domain_from_url(_), do: nil

  defp hostname(value) when is_binary(value) do
    uri = URI.parse(if(String.contains?(value, "://"), do: value, else: "https://" <> value))
    uri.host && String.trim_leading(uri.host, "www.")
  end

  defp hostname(_), do: nil

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, _} -> n
      :error -> default
    end
  end

  defp model(opts),
    do:
      Keyword.get(
        opts,
        :model_provider,
        Application.get_env(:neuron, :model, [])[:provider] || Neuron.Model.ZAI
      )

  defp decode(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    cleaned = String.replace(content, ~r/```(?:json)?/i, "") |> String.trim()

    case Regex.run(~r/\{.*\}/s, cleaned, capture: :first) do
      [json] -> Jason.decode(json)
      _ -> {:error, :invalid_model_json}
    end
  end

  defp decode(_), do: {:error, :invalid_model_response}
end

defmodule Neuron.Coordinator.Campaign do
  @moduledoc "gen_statem coordinator for campaign intake and target lead collection."
  @behaviour Neuron.Coordinator

  @impl true
  def plan(input, context), do: Neuron.Campaign.intake(input, context[:options] || [])

  @impl true
  def run(campaign, context),
    do:
      Neuron.Campaign.run(
        campaign,
        Keyword.put(context[:options] || [], :run_id, context[:run_id])
      )
end
