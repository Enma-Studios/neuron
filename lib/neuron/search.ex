defmodule Neuron.Search do
  @moduledoc "Search providers used by the intelligence exploration pipeline."

  # Every engine here must return public results to a signed-out cloud
  # browser. Google, LinkedIn, X and Reddit do not, so they ship switched
  # off; see `docs/configuration.md`.
  @default_engines [
    Neuron.Search.DuckDuckGo,
    Neuron.Search.Yandex
  ]

  @doc """
  Search the web for `query`. The model first tailors the query per
  platform — each engine has different ideal usage patterns — and the
  tailored searches run in parallel as concurrent browser pages. Results
  merge with engine attribution. Pass `:searches` to supply planned
  searches directly, or `:provider` to run one provider without planning.
  """
  def web(query, opts \\ []) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        provider.search(query, opts)

      searches = Keyword.get(opts, :searches) ->
        web_all(searches, opts)

      true ->
        with {:ok, searches} <- plan_searches(query, opts) do
          web_all(searches, opts)
        end
    end
  end

  @doc """
  Orchestrate planned searches end to end: one sub-agent per page renders
  the search in the fleet, and the model harvests prospect results from the
  page transcripts. Returns `{:ok, results, failures}`; failures carry
  per-search engine, query, and reason for the campaign ledger.
  """
  def orchestrate(searches, opts \\ []) do
    tasks = search_tasks(searches, opts)
    adapter = Keyword.get(opts, :page_adapter, Neuron.Search.Agent)

    case Neuron.Browser.Fleet.with_fleet(Keyword.put(opts, :page_adapter, adapter), fn fleet ->
           Neuron.Browser.Fleet.fetch_pages(fleet, tasks)
         end) do
      {:error, reason} ->
        {:error, {:search_unavailable, reason: {:fleet_unavailable, reason}}}

      pages when is_list(pages) ->
        task_by_id = Map.new(tasks, &{&1.id, &1})

        transcripts =
          for {_id, {:ok, transcript}} <- pages, is_map(transcript), do: transcript

        {open_transcripts, walled} =
          Enum.split_with(transcripts, fn transcript -> is_nil(wall_reason(transcript)) end)

        page_failures =
          for {id, {:error, reason}} <- pages, task = task_by_id[id] do
            %{
              engine: task.engine,
              query: task.query,
              kind: :page_failed,
              reason: inspect(reason)
            }
          end ++
            Enum.map(walled, fn transcript ->
              {kind, reason} = wall_reason(transcript)

              %{
                engine: transcript.engine,
                query: transcript.query,
                kind: kind,
                reason: reason
              }
            end)

        for failure <- page_failures do
          Neuron.Telemetry.emit(
            [:search, :engine_failed],
            Neuron.Telemetry.trace_metadata(opts)
            |> Map.merge(%{engine: inspect(failure.engine), reason: failure.reason})
          )
        end

        {found, harvest_failures} = Neuron.Search.Harvest.from_transcripts(open_transcripts, opts)
        merged = merge_results(found)
        failures = page_failures ++ harvest_failures

        # A round is unavailable only when no engine answered at all. An
        # engine that answered with nothing still carried the round, and a
        # walled or gated engine is a skipped engine, never a failed round.
        answered =
          MapSet.new(found, fn {engine, _results} -> engine end)

        if MapSet.size(answered) == 0 and failures != [] do
          {:error, {:search_unavailable, reason: {:all_searches_failed, failures}}}
        else
          {:ok, merged, failures}
        end
    end
  end

  @doc """
  Run planned searches — `%{engine: module, query: binary}` — as one fleet
  wave and merge the results. Every search opens its own browser page; the
  wave only fails when nothing at all was found.
  """
  def web_all(searches, opts \\ []) do
    tasks = search_tasks(searches, opts)

    pages =
      if tasks == [] do
        []
      else
        Neuron.Browser.Fleet.with_fleet(opts, fn fleet ->
          Neuron.Browser.Fleet.fetch_pages(fleet, tasks)
        end)
      end

    case pages do
      {:error, reason} ->
        {:error, {:search_unavailable, reason: {:fleet_unavailable, reason}}}

      pages when is_list(pages) ->
        task_by_id = Map.new(tasks, &{&1.id, &1})

        collected = for {id, page} <- pages, task = task_by_id[id], do: {task, page}
        {found, failures} = collect_engine_pages(collected)
        merged = merge_results(found)

        if merged == [] and failures != [] do
          {:error, {:search_unavailable, reason: {:engines_exhausted, failures}}}
        else
          {:ok, merged}
        end
    end
  end

  @doc "Resolve the engine set: call opts override application config overrides defaults."
  def engines(opts \\ []) do
    Keyword.get(opts, :engines) ||
      Application.get_env(:neuron, :search, [])[:engines] ||
      @default_engines
  end

  @doc "Expand one research goal into platform-tailored searches through the model."
  def plan_searches(query, opts) do
    enabled = engines(opts)

    assigns = %{
      query: query,
      engines: Enum.map_join(enabled, ", ", &"#{engine_id(&1)} (#{&1.kind()})")
    }

    Neuron.Telemetry.span(
      [:search, :plan],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:query, Neuron.Telemetry.summarize(query)),
      fn ->
        Neuron.Structured.generate(
          "search_plan.eex",
          assigns,
          &validate_searches(&1, enabled),
          opts
        )
      end
    )
  end

  @doc "Stable platform id for an engine module, used by planner prompts and validation."
  def engine_id(module) do
    module |> Module.split() |> List.last() |> String.downcase()
  end

  @doc """
  Build one fleet page task per planned search. Social engines receive the
  query with `site:` operators stripped; searches left with empty keywords
  are skipped so a web-scoped query never runs natively on a social
  platform. Searches naming engines outside the enabled set are dropped.
  """
  def search_tasks(searches, opts) do
    enabled = engines(opts)

    for search <- searches,
        engine = search.engine,
        engine in enabled,
        keywords = engine.keywords(search.query),
        is_binary(keywords) and keywords != "" do
      %{
        id: {engine, search.query},
        engine: engine,
        query: search.query,
        url: engine.search_url(keywords)
      }
    end
  end

  @doc """
  Collect engine page results into one merged list. Pages rendered as a bot
  wall or a login gate count as engine failures, not results.
  """
  def collect_engine_pages(pages) do
    Enum.reduce(pages, {[], []}, fn {task, page}, {found, failures} ->
      case engine_result(task, page) do
        {:ok, results} ->
          {[{task.engine, results} | found], failures}

        {:error, reason} ->
          Neuron.Telemetry.emit(
            [:search, :engine_failed],
            Neuron.Telemetry.trace_metadata([])
            |> Map.merge(%{engine: inspect(task.engine), reason: inspect(reason)})
          )

          {found, [{task.engine, reason} | failures]}
      end
    end)
  end

  @doc """
  Merge per-engine result lists into deduplicated results ranked by how
  many engines corroborate each URL.
  """
  def merge_results(engine_results) do
    engine_results
    |> Enum.flat_map(fn {engine, results} -> Enum.map(results, &{engine, &1}) end)
    |> Enum.reduce(%{}, fn {engine, result}, acc ->
      Map.update(acc, result.url, Map.put(result, :engines, [engine]), fn existing ->
        %{existing | engines: [engine | existing.engines]}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{-length(&1.engines)})
  end

  defp engine_result(task, {:ok, page}) do
    engine = task.engine
    html = page[:html] || page["html"] || ""

    cond do
      engine.blocked?(html) -> {:error, {:engine_blocked, engine}}
      engine.gated?(html) -> {:error, {:engine_gated, engine}}
      true -> {:ok, engine.parse(html)}
    end
  end

  defp engine_result(_task, {:error, reason}), do: {:error, reason}

  @doc """
  Validate planner output against the enabled engines: drop searches that
  name unknown platforms or carry empty queries, and deduplicate.
  """
  def validate_searches(%{"searches" => planned}, enabled) when is_list(planned) do
    searches =
      for %{"engine" => id, "query" => query} <- planned,
          is_binary(id) and is_binary(query) and String.trim(query) != "",
          engine = engine_for(id, enabled),
          do: %{engine: engine, query: String.trim(query)}

    searches
    |> Enum.uniq_by(&{&1.engine, &1.query})
    |> case do
      [] -> {:error, :no_valid_searches}
      searches -> {:ok, searches}
    end
  end

  def validate_searches(_other, _enabled), do: {:error, :expected_searches}

  @doc """
  How this page is walled, as `{kind, reason}`, or `nil` when it can be
  harvested. `kind` is `:login_gate`, `:consent_wall` or `:bot_check`, so a
  host can say which happened rather than only that something did.

  A login gate, a consent wall and a bot check all render a page with no
  results on it. Harvesting one yields nothing and looks identical to an
  engine that honestly found nothing, which is how three walled engines
  came to read as a working search that discovered no prospects. Each is
  recorded here as a skipped engine and nothing is ever done to get past
  one.
  """
  def wall_reason(transcript) do
    url = String.downcase(transcript[:url] || "")
    document = transcript[:document] || ""
    engine = transcript[:engine]

    cond do
      String.contains?(url, ["/authwall", "/login", "/signin", "/account/access"]) ->
        {:login_gate, "login gate at #{transcript.url}"}

      String.contains?(url, ["consent.", "/consent", "/sorry/", "/showcaptcha"]) ->
        {:consent_wall, "consent or bot wall at #{transcript.url}"}

      is_atom(engine) and not is_nil(engine) and engine.gated?(document) ->
        {:login_gate, "login gate at #{transcript.url}"}

      is_atom(engine) and not is_nil(engine) and engine.blocked?(document) ->
        {:bot_check, "bot check at #{transcript.url}"}

      true ->
        nil
    end
  end

  defp engine_for(id, enabled) do
    normalized = String.downcase(String.trim(id))
    Enum.find(enabled, &(engine_id(&1) == normalized))
  end
end

defmodule Neuron.Search.Engine do
  @moduledoc """
  Contract shared by browser-rendered search engines and native social
  platform searches. Engines normalize the query with `keywords/1`, render
  `search_url/1` in a browser page, and extract results with `parse/1`.
  """

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t()}

  @callback kind() :: :web | :social
  @callback keywords(query :: String.t()) :: String.t()
  @callback search_url(keywords :: String.t()) :: String.t()
  @callback parse(html :: String.t()) :: [result()]
  @callback blocked?(html :: String.t()) :: boolean()
  @callback gated?(html :: String.t()) :: boolean()

  @doc "Collapse tags, entities, and whitespace in scraped anchor text."
  def text(value) do
    value = Regex.replace(~r/<[^>]+>/, value, " ")

    value
    |> html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc "Decode the HTML entities emitted by engine result pages."
  def html_entities(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  @doc """
  Unwrap an engine's redirect link into the URL it actually points at.

  Result links in a rendered results page are the engine's own tracking
  redirects, so a transcript hands the model `duckduckgo.com/l/?uddg=...`
  rather than the prospect's page. Harvesting one ingests the search engine
  instead of the company, and records the engine as the organization. The
  per-engine parsers already unwrap these; the transcript path reads the
  DOM directly and needs the same treatment. A link that is not a known
  wrapper is returned unchanged.
  """
  def unwrap(href) when is_binary(href) do
    uri = URI.parse(href)
    host = String.downcase(uri.host || "")
    path = uri.path || ""
    params = if is_binary(uri.query), do: URI.decode_query(uri.query), else: %{}

    target =
      cond do
        String.contains?(host, "duckduckgo.com") -> params["uddg"]
        String.contains?(host, "google.") and path == "/url" -> params["q"] || params["url"]
        String.contains?(host, "yandex.") -> params["url"]
        true -> nil
      end

    if is_binary(target) and String.starts_with?(target, ["http://", "https://"]),
      do: target,
      else: href
  end

  def unwrap(href), do: href

  @doc """
  Drop `site:` operators so native social searches never see engine-scoped
  queries such as `site:linkedin.com founders`.
  """
  def strip_site_operators(query) when is_binary(query) do
    query
    |> String.split()
    |> Enum.reject(&(String.downcase(&1) |> String.starts_with?("site:")))
    |> Enum.join(" ")
    |> String.trim()
  end
end

defmodule Neuron.Search.DuckDuckGo do
  @moduledoc "DuckDuckGo HTML search through the Browser Use provider."
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [html_entities: 1, text: 1]

  @endpoint "https://html.duckduckgo.com/html/"

  @impl true
  def kind, do: :web

  @impl true
  def keywords(query), do: query

  @impl true
  def search_url(keywords), do: @endpoint <> "?" <> URI.encode_query(%{"q" => keywords})

  def search(query, opts \\ []) when is_binary(query) do
    url = search_url(query)

    browser_opts =
      opts |> Keyword.put(:provider, :browser_use) |> Keyword.put(:task_id, "search:duckduckgo")

    Neuron.Telemetry.span(
      [:search, :duckduckgo],
      Neuron.Telemetry.trace_metadata(browser_opts)
      |> Map.put(:query, Neuron.Telemetry.summarize(query)),
      fn ->
        with {:ok, page} <- Neuron.Browser.fetch(url, browser_opts),
             html when is_binary(html) <- page[:html] || page["html"],
             false <- blocked?(html) do
          {:ok, parse(html)}
        else
          true -> {:error, :duckduckgo_challenged}
          nil -> {:error, :search_returned_no_html}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  @impl true
  def parse(html) when is_binary(html) do
    snippets =
      Regex.scan(~r/<a[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)<\/a>/is, html,
        capture: :all_but_first
      )
      |> Enum.map(fn [snippet] -> text(snippet) end)

    Regex.scan(
      ~r/<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is,
      html,
      capture: :all_but_first
    )
    |> Enum.with_index()
    |> Enum.map(fn {[href, title], index} ->
      %{
        title: text(title),
        url: normalize_url(href),
        snippet: Enum.at(snippets, index, "")
      }
    end)
    |> Enum.reject(&(&1.url == ""))
    |> Enum.uniq_by(& &1.url)
  end

  @impl true
  def blocked?(html) do
    String.contains?(html, ["anomaly-modal", "challenge-form", "bots use DuckDuckGo"])
  end

  @impl true
  def gated?(_html), do: false

  defp normalize_url(href) do
    uri = URI.parse(html_entities(href))

    cond do
      is_binary(uri.query) and is_binary(uri.host) and
          String.contains?(uri.host, "duckduckgo.com") ->
        case URI.decode_query(uri.query)["uddg"] do
          target when is_binary(target) -> URI.decode(target)
          _ -> ""
        end

      String.starts_with?(href, "//") ->
        "https:" <> href

      String.starts_with?(href, "/") ->
        "https://duckduckgo.com" <> href

      true ->
        html_entities(href)
    end
  end
end
