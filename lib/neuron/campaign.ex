defmodule Neuron.Campaign do
  @moduledoc "Campaign intake and off-agent lead-count orchestration."

  @questions [
    %{
      key: :organization,
      label: "Organization",
      prompt: "What is your organization and website?",
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
      required: true
    },
    %{
      key: :geography,
      label: "Geography",
      prompt: "Which countries, regions, or markets should prospective customers be in?",
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
  def approve(%{campaigns: campaigns} = details, selection \\ :all) when is_list(campaigns) do
    partial = normalize_keys(Map.get(details, :partial, %{}))

    selected = select_campaigns(campaigns, selection)

    normalized =
      selected
      |> Enum.map(&(merge_nonblank(&1, partial) |> normalize_campaign()))
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
    opts = Keyword.drop(opts, [:run_id, :id])
    Enum.map(campaigns, &run(&1, opts))
  end

  # Supplied answers are inputs, not hints: the page fills only what was not
  # answered. A host sends every key and leaves the unanswered ones nil, so a
  # plain merge let those nils erase what the page did supply.
  defp intake_answers(answers, url, opts) do
    case scrape_answers(url, opts) do
      {:ok, scraped} ->
        supplied = for {key, value} <- answers, not blank?(value), do: key

        scraped
        |> Map.replace_lazy(:field_sources, &Map.drop(&1, supplied))
        |> merge_nonblank(answers)
        |> take()

      {:error, cause} ->
        without_scrape(answers, cause)
    end
  end

  # Scraping a URL fills answers that are missing. It is not a precondition
  # for answers that were supplied, and a caller who answered every question
  # must not be asked them all again because a page did not parse.
  defp without_scrape(answers, cause) do
    case take(answers) do
      {:ok, campaign} ->
        {:ok, campaign}

      {:needs_input, details} ->
        {:needs_input, Map.put(details, :scrape_error, cause)}

      other ->
        other
    end
  end

  defp take(merged) do
    with :ok <- approve_if_needed(merged),
         merged <- merge_approved_campaign(merged),
         {:ok, campaign} <- normalize_campaign(merged) do
      {:ok, campaign}
    end
  end

  defp approve_if_needed(%{candidate_campaigns: campaigns} = merged) when length(campaigns) > 1 do
    if merged[:approved_campaigns] || merged[:campaign_approval] do
      :ok
    else
      {:approval_required,
       %{
         campaigns: campaigns,
         partial:
           Map.drop(merged, [:candidate_campaigns, :approved_campaigns, :campaign_approval]),
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

  # Both sides share one key space first. A proposed campaign arrives from
  # the model with string keys and answers with atom keys, and merged apart
  # they both survived until `normalize_campaign/1` folded them together,
  # where the string key, sorting after every atom, overwrote the answer.
  defp merge_nonblank(base, overrides) do
    Enum.reduce(normalize_keys(overrides), normalize_keys(base), fn {key, value}, acc ->
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

  @doc "Start and await a durable prospect-discovery campaign."
  def run(campaign, opts \\ []) when is_map(campaign) do
    Neuron.run(Neuron.Coordinator.Campaign, %{approved_campaign: campaign}, opts)
  end

  defp scrape_answers(nil, _opts), do: {:ok, %{}}
  defp scrape_answers("", _opts), do: {:ok, %{}}

  defp scrape_answers(url, opts) when is_binary(url) do
    document = fn snapshot ->
      %{
        url: url,
        title: "",
        markdown: snapshot.markdown,
        published_at: nil,
        fetched_at: DateTime.utc_now()
      }
    end

    with {:ok, page} <- step(:fetch, Neuron.Browser.fetch(url, opts)),
         {:ok, html} <- step(:html, page[:html] || page["html"]),
         snapshot_attrs = %{url: url, title: page[:title], run_id: opts[:run_id]},
         {:ok, snapshot} <- step(:normalize, Neuron.Snapshot.from_html(html, snapshot_attrs)),
         attrs = %{document.(snapshot) | title: page[:title] || ""},
         {:ok, _} <- step(:save_document, Neuron.Knowledge.save_document(attrs, opts)),
         assigns = %{url: url, evidence: String.slice(snapshot.markdown, 0, 16_000)},
         {:ok, prompt} <-
           step(:prompt, Neuron.Prompt.render_file("campaign_intake.eex", assigns, opts)),
         messages = [
           %{role: "system", content: "Extract campaign facts as JSON only."},
           %{role: "user", content: prompt}
         ],
         {:ok, response} <-
           step(
             :model,
             model(opts).complete(messages, Keyword.put(opts, :task_id, "campaign:intake"))
           ),
         {:ok, parsed} <- step(:decode, decode(response)) do
      parsed = normalize_keys(parsed)

      {:ok,
       Map.drop(parsed, [:campaigns, "sources"])
       |> Map.put(:candidate_campaigns, List.wrap(parsed[:campaigns]))
       |> Map.put(:url, url)
       |> Map.put(:source_url, url)
       # The page's Markdown travels with the campaign so a host that never
       # reads Dgraph still has what the excerpts point into.
       # ponytail: the whole page is re-serialized at each stage checkpoint;
       # store it once against the run if a seller page ever gets large.
       |> Map.put(:source_markdown, snapshot.markdown)
       |> Map.put(:field_sources, field_sources(parsed["sources"], snapshot.markdown, url))}
    end
  end

  @doc """
  Anchor the model's quotes back into the page they came from.

  A summary is the model's sentence; an excerpt has to be the page's, so
  every quote is returned as the Markdown's own bytes and a host can find it
  there. A quote that differs only in whitespace is relocated; one that is
  nowhere on the page is dropped rather than shipped as evidence for a
  sentence nobody wrote.
  """
  def field_sources(sources, markdown, url) when is_map(sources) do
    for {key, quoted} <- sources,
        is_binary(quoted),
        excerpt = anchor(quoted, markdown),
        into: %{},
        do: {input_key(to_string(key)), %{excerpt: excerpt, source_url: url}}
  end

  def field_sources(_sources, _markdown, _url), do: %{}

  defp anchor(quoted, markdown) do
    quoted = String.trim(quoted)

    cond do
      quoted == "" -> nil
      String.contains?(markdown, quoted) -> quoted
      true -> relocate(quoted, markdown)
    end
  end

  defp relocate(quoted, markdown) do
    pattern = quoted |> String.split() |> Enum.map(&Regex.escape/1) |> Enum.join("\\s+")

    case Regex.run(~r/#{pattern}/u, markdown, return: :index) do
      [{start, length}] -> binary_part(markdown, start, length)
      _ -> nil
    end
  end

  # Each step says which step it was. The whole chain used to collapse into
  # one `{:error, reason}` and then into `:url_unavailable`, so a snapshot
  # that would not normalize, a prompt that would not render and a model that
  # timed out all read as a URL problem, on a site that returned 200.
  defp step(_stage, {:ok, value}), do: {:ok, value}
  defp step(stage, {:error, reason}), do: {:error, {stage, reason}}
  defp step(stage, nil), do: {:error, {stage, :missing}}
  defp step(_stage, value), do: {:ok, value}

  @doc "Validate a supplied or approved campaign brief."
  def normalize_campaign(values) do
    values = normalize_keys(values)
    seller = normalize_keys(values[:seller_profile] || %{})
    target = normalize_keys(values[:target_profile] || %{})

    values =
      Map.merge(
        %{
          organization: seller[:name] || seller[:domain],
          domain: seller[:domain],
          field: seller[:field] || profile_value(values[:fit_profile], "field"),
          offer: seller[:offer] || profile_value(values[:fit_profile], "offer"),
          seller_geography: seller[:geography],
          target_roles: target[:roles] || profile_value(values[:fit_profile], "target_role"),
          target_organizations: target[:markets] || profile_markets(values[:fit_profile]),
          geography: target[:geography],
          exclusions: target[:exclusions],
          industries: target[:industries],
          company_size: target[:company_size]
        },
        values
      )

    values =
      if blank?(values[:organization]) and not blank?(values[:domain]),
        do: Map.put(values, :organization, values[:domain]),
        else: values

    missing = missing_questions(values)

    if missing == [] do
      organization = values[:organization] || values[:domain]
      domain = seller_domain(values, organization)

      if is_binary(domain) and domain != "" do
        profile = fit_profile(values)

        seller = %{
          domain: domain,
          name: organization,
          field: values[:field],
          offer: values[:offer] || profile[:offer],
          geography: List.wrap(values[:seller_geography])
        }

        target = %{
          markets: List.wrap(values[:target_organizations] || profile[:target_organizations]),
          roles: List.wrap(values[:target_roles] || profile_value(profile, "target_role")),
          geography: List.wrap(values[:geography]),
          exclusions: exclusion_terms(values[:exclusions]),
          industries: List.wrap(values[:industries]),
          company_size: company_size(values[:company_size])
        }

        with {:ok, seller} <- Neuron.Contracts.validate(Neuron.Contracts.Seller, seller),
             {:ok, target} <- Neuron.Contracts.validate(Neuron.Contracts.Target, target),
             {:ok, campaign_id} <- Ecto.UUID.cast(values[:campaign_id] || Ecto.UUID.generate()) do
          {:ok,
           Map.merge(values, %{
             campaign_id: campaign_id,
             lead_count: parse_count(values[:lead_count]),
             domain: domain,
             seller_profile: Neuron.Contracts.plain(seller),
             target_profile: Neuron.Contracts.plain(target),
             fit_profile: profile
           })}
        else
          error -> {:error, {:invalid_campaign, error}}
        end
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

  defp satisfied_by_profile?(key, values)
       when key in [:field, :offer, :target_roles, :target_organizations],
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
        exclusions: exclusion_terms(values[:exclusions]),
        offer: values[:offer],
        threshold: values[:threshold] || 0.0
      }
  end

  # Exclusions are matched as substrings, so a sentence never matches
  # anything. Split deterministically into one term per clause: "Not
  # agencies, not security vendors." is ["agencies", "security vendors"].
  defp exclusion_terms(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), [",", ";"]))
    |> Enum.map(fn clause ->
      clause
      |> String.trim()
      |> String.replace(~r/^(not|no)\s+/i, "")
      |> String.replace(~r/[.!]+$/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # `%{min:, max:}` in employees, either bound optional.
  defp company_size(%{} = range) do
    bound = fn key -> Map.get(range, key, Map.get(range, to_string(key))) end
    %{min: bound.(:min), max: bound.(:max)}
  end

  defp company_size(_), do: nil

  defp profile_value(profile, category) when is_map(profile) do
    profile
    |> Map.get(:requirements, Map.get(profile, "requirements", []))
    |> List.wrap()
    |> Enum.filter(fn requirement ->
      is_map(requirement) and
        Map.get(requirement, :category, Map.get(requirement, "category")) == category
    end)
    |> Enum.map(&Map.get(&1, :description, Map.get(&1, "description")))
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      [value] -> value
      values -> values
    end
  end

  defp profile_value(_, _), do: nil

  defp profile_markets(profile) when is_map(profile),
    do: Map.get(profile, :target_organizations, Map.get(profile, "target_organizations"))

  defp profile_markets(_), do: nil

  defp normalize_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {input_key(k), v} end)

  defp normalize_keys(other), do: other

  @input_keys ~w(organization domain field offer name url website seller_geography target_roles target_organizations geography exclusions industries company_size lead_count campaign_id seller_profile target_profile roles markets fit_profile preferred_geographies threshold assertions action campaigns candidate_campaigns approved_campaigns campaign_approval)a
  defp input_key(key) when is_binary(key),
    do: Enum.find(@input_keys, key, &(Atom.to_string(&1) == key))

  defp input_key(key), do: key

  # The seller's domain decides whose people are never leads, so it comes
  # from the input URL whenever there is one. `domain` is an extracted field,
  # and intake returned a phrase from the page there on run 92450aed.
  defp seller_domain(values, organization) do
    url = Enum.find([values[:url], values[:website], values[:source_url]], &(not blank?(&1)))
    Neuron.Knowledge.registrable_domain(url || values[:domain] || hostname(organization))
  end

  defp hostname(value) when is_binary(value) do
    uri = URI.parse(if(String.contains?(value, "://"), do: value, else: "https://" <> value))
    uri.host && String.trim_leading(uri.host, "www.")
  end

  defp hostname(_), do: nil

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp parse_count(value) when is_integer(value) and value > 0, do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> raise ArgumentError, "lead_count must be a positive integer"
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
  @moduledoc "Durable campaign intake and target lead collection profile."
  @behaviour Neuron.Coordinator

  @impl true
  def plan(%{approved_campaign: campaign}, _context),
    do: Neuron.Campaign.normalize_campaign(campaign)

  def plan(input, context), do: Neuron.Campaign.intake(input, context[:options] || [])

  defdelegate stages(), to: Neuron.CampaignPipeline
  defdelegate stage(stage, data, opts), to: Neuron.CampaignPipeline
  @impl true
  def run(_campaign, _context), do: raise("campaigns execute as checkpointed stages")
end
