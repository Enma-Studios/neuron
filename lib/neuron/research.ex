defmodule Neuron.Research do
  @moduledoc "Search, browse, extract, qualify, and return campaign leads."

  @default_queries [
    "<%=DOMAIN%> leadership founders team contact",
    "site:linkedin.com/in <%=DOMAIN%> founder OR CEO OR director",
    "<%=DOMAIN%> clients partnerships people"
  ]

  def run(domain, fit_profile, opts \\ []) when is_binary(domain) and is_map(fit_profile) do
    id = Keyword.get(opts, :run_id, Ecto.UUID.generate())

    if is_nil(Neuron.Persistence.repo().get(Neuron.FSM.Machine, id)) do
      {:ok, ^id} =
        Neuron.start_run(
          Neuron.Coordinator.LeadGeneration,
          %{domain: domain, fit_profile: fit_profile},
          Keyword.put(opts, :id, id)
        )
    end

    with {:ok, response} <- Neuron.await_run(id, Keyword.get(opts, :timeout, 900_000)) do
      {:ok, response.result}
    end
  end

  def stages, do: [:discover, :browse, :extract, :enrich, :draft, :persist]

  def stage(:discover, data, opts) do
    with {:ok, results} <- discover(data.domain, opts),
         do: {:ok, Map.put(data, :search_results, results)}
  end

  def stage(:browse, data, opts) do
    with {:ok, pages} <- browse_sources(data.search_results, opts),
         do: {:ok, Map.put(data, :pages, pages)}
  end

  def stage(:extract, data, opts) do
    with {:ok, value} <-
           extract(data.domain, data.fit_profile, data.search_results, data.pages, opts),
         do: {:ok, Map.put(data, :extraction, value)}
  end

  def stage(:enrich, data, opts) do
    with {:ok, value} <-
           re_enrich(
             data.domain,
             data.fit_profile,
             data.extraction,
             data.search_results,
             data.pages,
             opts
           ),
         do: {:ok, Map.put(data, :extraction, value)}
  end

  def stage(:draft, data, opts) do
    with {:ok, drafts} <- draft_emails(data.domain, data.extraction, data.pages, opts),
         result =
           normalize_result(
             data.domain,
             data.fit_profile,
             data.extraction,
             drafts,
             data.pages,
             opts
           ),
         {:ok, confirmed} <- confirm_research_output(result, opts),
         do: {:ok, Map.put(data, :confirmed, confirmed)}
  end

  def stage(:persist, data, opts) do
    with :ok <- persist_graph(graph_facts(data.confirmed, data.pages, opts), opts[:run_id], opts),
         do: {:ok, Map.merge(data.confirmed, %{run_id: opts[:run_id], sources: data.pages})}
  end

  defp persist_graph(graph, run_id, opts) do
    if Keyword.get(opts, :persist, true) do
      Neuron.Graph.upsert(graph, run_id: run_id, task_id: "research:graph_upsert")
    else
      :ok
    end
  end

  defp confirm_research_output(result, opts) do
    case Neuron.Schemas.validate_research(result) do
      {:ok, _validated} ->
        {:ok, result}

      {:error, errors} ->
        Neuron.Telemetry.emit(
          [:research, :output_confirmation],
          Neuron.Telemetry.trace_metadata(opts)
          |> Map.put(:validation_errors, Neuron.Telemetry.summarize(errors))
        )

        with {:ok, prompt} <-
               Neuron.Prompt.render_file(
                 "confirm_output.eex",
                 %{output: inspect(result), errors: inspect(errors)},
                 opts
               ),
             {:ok, response} <-
               model(opts).complete(
                 [
                   %{
                     role: "system",
                     content: "Confirm and repair the research JSON. Return JSON only."
                   },
                   %{role: "user", content: prompt}
                 ],
                 Keyword.put(opts, :task_id, "research:confirm_output")
               ),
             {:ok, parsed} <- decode_response(response),
             sanitized <-
               Neuron.Schemas.sanitize_research(Map.put(parsed, "domain", result.domain)),
             {:ok, _validated} <- Neuron.Schemas.validate_research(sanitized) do
          {:ok, Map.merge(result, sanitized)}
        else
          {:error, reason} -> {:error, {:invalid_research_result, errors, reason}}
        end
    end
  end

  defp discover(domain, opts) do
    queries =
      Keyword.get(opts, :queries, @default_queries)
      |> Enum.map(&String.replace(&1, "<%=DOMAIN%>", domain))

    results =
      queries
      |> Neuron.Pipeline.map(
        fn query -> Neuron.Search.DuckDuckGo.search(query, opts) end,
        max_concurrency: Keyword.get(opts, :search_concurrency, 2)
      )
      |> Enum.flat_map(fn
        {:ok, found} -> found
        {:error, reason} -> raise "search failed: #{inspect(reason)}"
      end)
      |> Kernel.++(site_seeds(domain))
      |> Enum.filter(&http_url?(&1[:url]))
      |> Enum.filter(&Neuron.ContactPolicy.prospect_source?(&1[:url]))
      |> Enum.uniq_by(& &1.url)
      |> Enum.sort_by(&{-source_priority(&1.url, domain), &1.url})
      |> Enum.take(Keyword.get(opts, :max_sources, 8))

    Neuron.Telemetry.emit(
      [:research, :discovery],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:count, length(results))
    )

    if results == [], do: {:error, :no_search_results}, else: {:ok, results}
  end

  defp site_seeds(domain) do
    base = "https://" <> String.trim_leading(domain, "https://")

    [
      "",
      "/about",
      "/team",
      "/research",
      "/work",
      "/contact"
    ]
    |> Enum.map(fn path -> %{title: domain, url: base <> path, snippet: "First-party source"} end)
  end

  defp browse_sources(search_results, opts) do
    pages =
      search_results
      |> Neuron.Pipeline.map(
        fn result -> browse(result, opts) end,
        max_concurrency: Keyword.get(opts, :browser_concurrency, 3)
      )
      |> Enum.flat_map(fn
        {:ok, page} ->
          [page]

        {:error, reason} ->
          Neuron.Telemetry.emit(
            [:research, :source_failed],
            Map.put(Neuron.Telemetry.trace_metadata(opts), :reason, inspect(reason))
          )

          []
      end)

    if pages == [], do: {:error, :no_browsable_sources}, else: {:ok, pages}
  end

  defp browse(result, opts) do
    url = result.url

    with {:ok, page} <- Neuron.Browser.fetch(url, opts),
         html when is_binary(html) <- page[:html] || page["html"],
         {:ok, snapshot} <-
           Neuron.Snapshot.from_html(html, %{
             url: url,
             title: page[:title] || result.title,
             run_id: opts[:run_id]
           }) do
      {:ok,
       %{
         url: url,
         title: snapshot.title || result.title,
         markdown: String.slice(snapshot.markdown, 0, 8_000),
         snippet: result[:snippet] || "",
         provider: page[:provider]
       }}
    else
      nil -> {:error, :source_without_html}
      {:error, reason} -> {:error, {url, reason}}
    end
  end

  defp extract(domain, fit_profile, search_results, pages, opts) do
    evidence = evidence(search_results, pages)

    template =
      Neuron.Prompt.render_file(
        "research_extract.eex",
        %{
          domain: domain,
          fit_profile: inspect(fit_profile),
          assertions: inspect(assertions(opts, fit_profile)),
          evidence: evidence
        },
        opts
      )

    with {:ok, prompt} <- template,
         {:ok, response} <-
           model(opts).complete(
             [
               %{
                 role: "system",
                 content: "You extract verifiable intelligence. Return JSON only."
               },
               %{role: "user", content: prompt}
             ],
             Keyword.put(opts, :task_id, "research:extract")
           ),
         {:ok, parsed} <- decode_response(response),
         sanitized <- Neuron.Schemas.sanitize_research(Map.put(parsed, "domain", domain)),
         {:ok, _validated} <- Neuron.Schemas.validate_research(sanitized) do
      Neuron.Telemetry.emit(
        [:research, :extraction],
        Neuron.Telemetry.trace_metadata(opts)
        |> Map.merge(%{
          people: length(list(parsed, "people")),
          leads: length(list(parsed, "leads"))
        })
      )

      {:ok, sanitized}
    end
  end

  defp re_enrich(domain, fit_profile, extraction, search_results, pages, opts) do
    if Keyword.get(opts, :re_enrich, true) do
      template =
        Neuron.Prompt.render_file(
          "re_enrich.eex",
          %{
            domain: domain,
            fit_profile: inspect(fit_profile),
            initial: inspect(extraction),
            evidence: evidence(search_results, pages)
          },
          opts
        )

      with {:ok, prompt} <- template,
           {:ok, response} <-
             model(opts).complete(
               [
                 %{role: "system", content: "You reconcile evidence and return JSON only."},
                 %{role: "user", content: prompt}
               ],
               Keyword.put(opts, :task_id, "research:re_enrich")
             ),
           {:ok, parsed} <- decode_response(response),
           sanitized <- Neuron.Schemas.sanitize_research(Map.put(parsed, "domain", domain)),
           {:ok, _validated} <- Neuron.Schemas.validate_research(sanitized) do
        Neuron.Telemetry.emit(
          [:research, :re_enriched],
          Neuron.Telemetry.trace_metadata(opts)
          |> Map.merge(%{
            people: length(list(sanitized, "people")),
            leads: length(list(sanitized, "leads"))
          })
        )

        {:ok, sanitized}
      end
    else
      {:ok, extraction}
    end
  end

  defp draft_emails(domain, extraction, pages, opts) do
    template =
      Neuron.Prompt.render_file(
        "draft_emails.eex",
        %{
          domain: domain,
          organization: inspect(map(extraction, "organization")),
          leads: inspect(list(extraction, "leads")),
          target_profile: inspect(map(extraction, "target_profile")),
          evidence_urls: inspect(Enum.map(pages, & &1.url)),
          assertions: inspect(opts[:assertions] || [])
        },
        opts
      )

    with {:ok, prompt} <- template,
         {:ok, response} <-
           model(opts).complete(
             [
               %{
                 role: "system",
                 content: "You write evidence-grounded outreach. Return JSON only."
               },
               %{role: "user", content: prompt}
             ],
             Keyword.put(opts, :task_id, "research:draft_email")
           ),
         {:ok, parsed} <- decode_response(response) do
      {:ok, parsed}
    end
  end

  defp normalize_result(domain, fit_profile, extraction, drafts, pages, opts) do
    organization =
      map(extraction, "organization")
      |> Map.put_new("domain", domain)
      |> Map.put_new("contact_email", extract_email(pages, domain))

    people =
      list(extraction, "people")
      |> Enum.filter(&target_person?(&1, domain, fit_profile))
      |> Enum.map(fn person ->
        Map.put(
          person,
          "contact_suggestions",
          Neuron.ContactPolicy.suggestions(person, domain,
            preferred_geographies:
              Map.get(
                fit_profile,
                :preferred_geographies,
                Map.get(fit_profile, "preferred_geographies", [])
              )
          )
        )
      end)

    extracted_leads = list(extraction, "leads")
    email_map = Map.new(list(drafts, "emails"), &{string(&1["person_name"]), &1})

    leads =
      extracted_leads
      |> Enum.map(fn lead ->
        person_name = string(lead["person_name"])
        Map.merge(lead, Map.get(email_map, person_name, %{}))
      end)
      |> Enum.filter(fn lead ->
        Enum.any?(people, &(string(&1["name"]) == string(lead["person_name"])))
      end)
      |> Enum.filter(&(string(&1["person_name"]) != ""))

    %{
      domain: domain,
      fit_profile: fit_profile,
      organization: organization,
      people: people,
      posts: list(extraction, "posts"),
      leads: leads,
      drafts: list(drafts, "emails"),
      assertions: assertions(opts, fit_profile),
      target_profile:
        map(drafts, "target_profile") |> Map.merge(map(extraction, "target_profile")),
      source_urls: Enum.map(pages, & &1.url)
    }
  end

  defp graph_facts(result, pages, opts) do
    domain = result.domain
    org_uid = blank_uid("org", domain)
    source_nodes = Enum.map(pages, &source_node(&1, opts))
    source_refs = Enum.map(source_nodes, &%{"uid" => &1["uid"]})

    organization = Map.put(result.organization, "assertions", result.assertions)

    organization_socials =
      Enum.map(list(organization, "social_accounts"), &social_node(&1, org_uid, domain))

    assertion_nodes =
      Enum.map(result.assertions, fn assertion ->
        %{
          "uid" => blank_uid("assertion", domain <> inspect(assertion)),
          "dgraph.type" => ["Assertion", "Entity"],
          "predicate" =>
            string(assertion["predicate"] || assertion[:predicate] || "user_assertion"),
          "excerpt" =>
            string(assertion["text"] || assertion[:text] || assertion["description"] || assertion),
          "confidence" => 1.0,
          "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "sources" => source_refs
        }
        |> drop_blanks()
      end)

    geographies = Enum.map(list(organization, "geographies"), &geography_node(&1, domain))

    requirements =
      Enum.map(list(organization, "requirements"), &requirement_node(&1, org_uid, domain, opts))

    leniencies =
      Enum.map(list(organization, "leniencies"), &leniency_node(&1, org_uid, domain, opts))

    capabilities =
      Enum.map(list(organization, "capabilities"), &capability_node(&1, domain, opts))

    clients = Enum.map(list(organization, "clients"), &client_node(&1, org_uid, domain, opts))

    people_nodes =
      Enum.map(result.people, fn person ->
        uid = blank_uid("person", domain <> string(person["name"]))

        %{
          "uid" => uid,
          "dgraph.type" => ["Person", "Entity"],
          "name" => string(person["name"]),
          "title" => string(person["title"]),
          "bio" => string(person["bio"]),
          "profile_url" => string(person["profile_url"]),
          "employer" => %{"uid" => org_uid},
          "social_accounts" =>
            Enum.map(list(person, "social_accounts"), &social_node(&1, uid, domain)),
          "sources" => source_refs,
          Neuron.Embedding.field() =>
            embedding(string(person["bio"]) <> " " <> string(person["title"]), opts)
        }
        |> drop_blanks()
      end)

    people_by_name = Map.new(people_nodes, &{&1["name"], &1["uid"]})

    posts_nodes =
      Enum.map(result.posts, fn post ->
        author_uid = Map.get(people_by_name, string(post["author_name"]))

        %{
          "uid" => blank_uid("post", domain <> string(post["url"] || post["title"])),
          "dgraph.type" => ["Post", "Entity"],
          "title" => string(post["title"]),
          "body" => string(post["body"]),
          "url" => string(post["url"]),
          "author" => if(author_uid, do: %{"uid" => author_uid}),
          "organization" => %{"uid" => org_uid},
          "topics" => list(post, "topics"),
          "sources" => source_refs,
          Neuron.Embedding.field() => embedding(string(post["body"]), opts)
        }
        |> drop_blanks()
      end)

    lead_nodes =
      Enum.map(result.leads, fn lead ->
        person_uid = Map.get(people_by_name, string(lead["person_name"]))

        %{
          "uid" => blank_uid("lead", domain <> string(lead["person_name"])),
          "dgraph.type" => ["Lead", "Entity"],
          "name" => string(lead["person_name"]),
          "person" => if(person_uid, do: %{"uid" => person_uid}),
          "organization" => %{"uid" => org_uid},
          "fit_score" => number(lead["fit_score"]),
          "reason" => string(lead["reason"]),
          "email" => string(lead["email"]),
          "email_subject" => string(lead["email_subject"] || lead["subject"]),
          "email_body" => string(lead["email_body"] || lead["body"]),
          "target_profile" => Jason.encode!(result.target_profile),
          "sources" => source_refs
        }
        |> drop_blanks()
      end)

    %{
      "uid" => org_uid,
      "dgraph.type" => ["Organization", "Entity"],
      "name" =>
        if(string(result.organization["name"]) == "",
          do: domain,
          else: string(result.organization["name"])
        ),
      "domain" => domain,
      "contact_email" => string(result.organization["contact_email"]),
      "description" => string(result.organization["description"]),
      "industry" => string(result.organization["industry"]),
      "organization_type" => string(result.organization["organization_type"]),
      "people" => people_nodes,
      "social_accounts" => organization_socials,
      "geographies" => geographies,
      "requirements" => requirements,
      "leniencies" => leniencies,
      "capabilities" => capabilities,
      "clients" => clients,
      "posts" => posts_nodes,
      "assertions" => assertion_nodes,
      "leads" => lead_nodes,
      "sources" => source_nodes,
      Neuron.Embedding.field() => embedding(string(result.target_profile["summary"]), opts)
    }
    |> drop_blanks()
  end

  defp source_node(page, _opts),
    do: %{
      "uid" => blank_uid("source", page.url),
      "dgraph.type" => ["Source", "Entity"],
      "url" => page.url,
      "title" => page.title,
      "content_hash" => Base.encode16(:crypto.hash(:sha256, page.markdown), case: :lower),
      "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "snapshot" => %{
        "dgraph.type" => ["Snapshot", "Entity"],
        "markdown" => page.markdown,
        "content_hash" => Base.encode16(:crypto.hash(:sha256, page.markdown), case: :lower),
        "extraction_version" => 1
      }
    }

  defp social_node(account, owner_uid, domain) do
    profile_url = field(account, "profile_url")
    handle = field(account, "handle")

    %{
      "uid" => blank_uid("social", domain <> string(profile_url || handle || account)),
      "dgraph.type" => ["SocialAccount", "Entity"],
      "platform" => string(field(account, "platform")),
      "handle" => string(handle),
      "profile_url" => string(profile_url || if(is_binary(account), do: account)),
      "display_name" => string(field(account, "display_name")),
      "owner" => %{"uid" => owner_uid}
    }
    |> drop_blanks()
  end

  defp geography_node(geography, domain) do
    %{
      "uid" => blank_uid("geography", domain <> string(field(geography, "name") || geography)),
      "dgraph.type" => ["Geography", "Entity"],
      "name" => string(field(geography, "name") || geography),
      "country_code" => string(field(geography, "country_code")),
      "kind" => string(field(geography, "kind"))
    }
    |> drop_blanks()
  end

  defp requirement_node(requirement, owner_uid, domain, opts) do
    %{
      "uid" => blank_uid("requirement", domain <> inspect(requirement)),
      "dgraph.type" => ["Requirement", "Entity"],
      "category" => string(field(requirement, "category")),
      "description" => string(field(requirement, "description") || requirement),
      "required_by" => %{"uid" => owner_uid},
      Neuron.Embedding.field() =>
        embedding(string(field(requirement, "description") || requirement), opts)
    }
    |> drop_blanks()
  end

  defp leniency_node(leniency, owner_uid, domain, opts) do
    %{
      "uid" => blank_uid("leniency", domain <> inspect(leniency)),
      "dgraph.type" => ["Leniency", "Entity"],
      "category" => string(field(leniency, "category")),
      "description" => string(field(leniency, "description") || leniency),
      "subject" => %{"uid" => owner_uid},
      "score" => number(field(leniency, "score")),
      Neuron.Embedding.field() =>
        embedding(string(field(leniency, "description") || leniency), opts)
    }
    |> drop_blanks()
  end

  defp capability_node(capability, domain, opts) do
    %{
      "uid" => blank_uid("capability", domain <> inspect(capability)),
      "dgraph.type" => ["Capability", "Entity"],
      "name" => string(field(capability, "name") || capability),
      "description" => string(field(capability, "description")),
      "category" => string(field(capability, "category")),
      Neuron.Embedding.field() =>
        embedding(
          string(field(capability, "description") || field(capability, "name") || capability),
          opts
        )
    }
    |> drop_blanks()
  end

  defp client_node(client, owner_uid, domain, opts) do
    %{
      "uid" => blank_uid("client", domain <> inspect(client)),
      "dgraph.type" => ["ClientProfile", "Entity"],
      "name" => string(field(client, "name") || client),
      "summary" => string(field(client, "summary") || field(client, "description")),
      "industry" => string(field(client, "industry")),
      "client_of" => %{"uid" => owner_uid},
      Neuron.Embedding.field() =>
        embedding(
          string(
            field(client, "summary") || field(client, "description") || field(client, "name") ||
              client
          ),
          opts
        )
    }
    |> drop_blanks()
  end

  defp evidence(search_results, pages) do
    search =
      Enum.map(search_results, fn result ->
        "SEARCH #{result.title} | #{result.url}\n#{result.snippet}"
      end)

    browsed = Enum.map(pages, fn page -> "PAGE #{page.title} | #{page.url}\n#{page.markdown}" end)
    Enum.join(search ++ browsed, "\n\n") |> String.slice(0, 35_000)
  end

  defp decode_response(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    cleaned =
      content
      |> String.replace(~r/```(?:json)?/i, "")
      |> String.trim()

    json = Regex.run(~r/\{.*\}/s, cleaned, capture: :first)

    case json && Jason.decode(hd(json)) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_model_json, reason, String.slice(content, 0, 500)}}
      nil -> {:error, {:invalid_model_json, :missing_object, String.slice(content, 0, 500)}}
    end
  end

  defp decode_response(other), do: {:error, {:invalid_model_response, other}}

  defp assertions(opts, fit_profile) do
    (Keyword.get(opts, :assertions) ||
       Map.get(fit_profile, :assertions, Map.get(fit_profile, "assertions", [])))
    |> List.wrap()
  end

  defp target_person?(person, domain, fit_profile),
    do:
      Neuron.ContactPolicy.eligible?(person, domain,
        preferred_geographies:
          Map.get(
            fit_profile,
            :preferred_geographies,
            Map.get(fit_profile, "preferred_geographies", [])
          )
      )

  defp extract_email(pages, domain) do
    domain = Regex.escape(domain)

    pages
    |> Enum.map(& &1.markdown)
    |> Enum.join("\n")
    |> then(&Regex.run(~r/[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\.)*#{domain}/i, &1, capture: :first))
    |> case do
      [email] -> String.downcase(email)
      _ -> nil
    end
  end

  defp field(value, key, default \\ nil)

  defp field(value, key, default) when is_map(value),
    do: Map.get(value, key, Map.get(value, String.to_atom(key), default))

  defp field(_value, _key, default), do: default

  defp model(opts),
    do:
      Keyword.get(
        opts,
        :model_provider,
        Application.get_env(:neuron, :model, [])[:provider] || Neuron.Model.ZAI
      )

  defp list(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key), [])) |> List.wrap()

  defp map(map, key),
    do:
      Map.get(map, key, Map.get(map, String.to_atom(key), %{}))
      |> then(&if(is_map(&1), do: &1, else: %{}))

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value) when is_map(value) or is_list(value), do: inspect(value)
  defp string(value), do: to_string(value)
  defp number(nil), do: 0.0
  defp number(value) when is_number(value), do: value

  defp number(value) do
    case Float.parse(string(value)) do
      {number, _} -> number
      :error -> 0.0
    end
  end

  defp http_url?(url) when is_binary(url),
    do: String.starts_with?(url, "http://") or String.starts_with?(url, "https://")

  defp http_url?(_), do: false

  defp source_priority(url, domain) do
    host = URI.parse(url).host || ""

    cond do
      host == domain or String.ends_with?(host, ".#{domain}") -> 100
      host in ["linkedin.com", "www.linkedin.com"] -> 90
      host in ["x.com", "www.x.com", "twitter.com", "www.twitter.com"] -> 80
      true -> 10
    end
  end

  defp blank_uid(kind, value),
    do:
      "_:#{kind}-#{Base.encode16(:crypto.hash(:sha256, value), case: :lower) |> binary_part(0, 20)}"

  defp embedding("", _opts), do: nil

  defp embedding(text, opts) do
    case Neuron.Embedding.provider().embed(text, opts) do
      {:ok, vector} -> vector
      {:error, reason} -> raise "embedding failed: #{inspect(reason)}"
    end
  end

  defp drop_blanks(map),
    do:
      Enum.reject(map, fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
      |> Map.new()
end

defmodule Neuron.Coordinator.LeadGeneration do
  @moduledoc "Coordinator profile for complete search-to-lead generation runs."
  @behaviour Neuron.Coordinator

  @impl true
  def plan(input, _context) when is_map(input) do
    domain = input[:domain] || input["domain"]
    fit_profile = input[:fit_profile] || input["fit_profile"] || %{}

    if is_binary(domain) and domain != "",
      do: {:ok, %{domain: domain, fit_profile: fit_profile}},
      else: {:error, :no_domain}
  end

  defdelegate stages(), to: Neuron.Research
  defdelegate stage(name, data, opts), to: Neuron.Research

  @impl true
  def run(%{domain: domain, fit_profile: fit_profile}, context) do
    opts = Keyword.put(context[:options] || [], :run_id, context[:run_id])
    Neuron.Research.run(domain, fit_profile, opts)
  end
end
