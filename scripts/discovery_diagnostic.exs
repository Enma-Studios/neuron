# Discovery diagnostic for Neureni issue #43.
#
# Runs ONE campaign search round on the public keyword engines only, against
# the intake answers recorded in the spike handoff, and logs what each engine
# actually returned and what the harvest step did with it.
#
#   BROWSER_USE_API_KEY=... ZAI_API_KEY=... \
#     mix run --no-start scripts/discovery_diagnostic.exs
#
# No BROWSER_USE_PROFILE_ID is set and none must be: the question is whether
# discovery works in the only configuration the Neureni host runs. Consent
# walls, login gates and bot checks are recorded and skipped, never worked
# around.
#
# Runs with --no-start and boots only what search needs, so it does not
# require Dgraph, the repository, Oban, or the embedding model.

{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:pinocchio)
{:ok, _} = DynamicSupervisor.start_link(name: Neuron.PipelineSupervisor, strategy: :one_for_one)
{:ok, _} = Neuron.Browser.Sessions.start_link([])

engines = [Neuron.Search.DuckDuckGo, Neuron.Search.Google, Neuron.Search.Yandex]

# The spike's intake answers, verbatim from Enma-Studios/neureni
# test/support/neuron_result.json.
seller_profile = %{
  name: "Enma Studios",
  domain: "Enma Studios",
  field:
    "Software product studio building custom software, product builds, rebuilds and extensions for companies without engineering capacity",
  offer:
    "A small senior team that builds, rebuilds or extends your product when you have something to ship and no engineering capacity to ship it. Faster and cheaper than an agency, less risky than a freelancer.",
  geography: []
}

target_profile = %{
  markets: [
    "Companies with 10 to 80 people and fewer than five engineers",
    "Companies with a product or internal tool to build, rebuild or extend",
    "Companies with open engineering roles they cannot fill"
  ],
  roles: ["Founder", "Co-founder", "CTO", "Head of Product", "Product lead"],
  geography: [],
  exclusions: []
}

defmodule Diagnostic do
  @moduledoc """
  A search page adapter that returns the ordinary transcript plus the raw
  document, so the diagnostic can ask each engine whether the page it was
  handed was a results page, a bot check, or a consent wall.
  """

  def run_page(handle, task, opts) do
    timeout = Keyword.get(opts, :timeout, 45_000)
    page = Neuron.Browser.Fleet.Target.open(handle.session)

    try do
      _ = Pinocchio.Browser.visit(page, task.url)
      _ = Neuron.Browser.Fleet.CDP.wait_ready(page, task.url, timeout)

      _ =
        Pinocchio.Browser.execute_script(
          page,
          "window.scrollTo(0, Math.max(1, document.body.scrollHeight - 1200))"
        )

      Process.sleep(800)

      html =
        try do
          Pinocchio.Browser.page_source(page)
        rescue
          _ -> ""
        end

      case Neuron.Browser.Scripting.extract(page) do
        {:ok, raw} ->
          {:ok, raw |> Neuron.Search.Agent.normalize(task) |> Map.put(:html, html)}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Neuron.Browser.Fleet.Target.close(page)
    end
  end

  def log(line), do: IO.puts(line)

  def hosts(links) do
    links
    |> Enum.map(&(URI.parse(&1.href).host || ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_host, count} -> -count end)
  end
end

Diagnostic.log("# Discovery diagnostic, Neureni issue #43")
Diagnostic.log("")
Diagnostic.log("Run at #{DateTime.utc_now() |> DateTime.to_iso8601()}")

Diagnostic.log(
  "Engines: #{Enum.map_join(engines, ", ", &Neuron.Search.engine_id/1)}"
)

Diagnostic.log(
  "BROWSER_USE_PROFILE_ID: #{inspect(System.get_env("BROWSER_USE_PROFILE_ID"))} (must be nil)"
)

Diagnostic.log("")

# `timeout:` is read by both the browser and the model provider, so the two
# are kept apart here rather than capping a model call at a page budget.
opts = [
  engines: engines,
  seller_domain: seller_profile.domain,
  sessions: 1,
  pages_per_session: 3,
  timeout: 45_000,
  harvest_concurrency: 2
]

model_opts =
  opts |> Keyword.delete(:timeout) |> Keyword.put(:timeout, 300_000)

# Stage 1: plan_search, using the production campaign_search prompt.
Diagnostic.log("## 1. plan_search")
Diagnostic.log("")

{:ok, searches} =
  Neuron.Structured.generate(
    "campaign_search.eex",
    %{
      seller: inspect(seller_profile),
      target: inspect(target_profile),
      previous_searches: inspect([]),
      failures: inspect([]),
      leads: inspect(%{selected: [], candidates_needing_enrichment: []}),
      engines: Enum.map_join(engines, ", ", &Neuron.Search.engine_id(&1))
    },
    &Neuron.Search.validate_searches(&1, engines),
    model_opts
  )

searches = Enum.take(searches, 6)

for search <- searches do
  Diagnostic.log("- #{Neuron.Search.engine_id(search.engine)}: #{search.query}")
end

Diagnostic.log("")
Diagnostic.log("Planned #{length(searches)} searches.")
Diagnostic.log("")

tasks = Neuron.Search.search_tasks(searches, opts)

# Stage 2: run the fleet wave and describe every page that came back.
Diagnostic.log("## 2. search, per page")
Diagnostic.log("")

pages =
  Neuron.Browser.Fleet.with_fleet(Keyword.put(opts, :page_adapter, Diagnostic), fn fleet ->
    Neuron.Browser.Fleet.fetch_pages(fleet, tasks)
  end)

task_by_id = Map.new(tasks, &{&1.id, &1})

transcripts =
  for {id, result} <- pages do
    task = Map.fetch!(task_by_id, id)
    engine = task.engine

    Diagnostic.log("### #{Neuron.Search.engine_id(engine)}: #{task.query}")
    Diagnostic.log("")
    Diagnostic.log("Requested: #{task.url}")

    case result do
      {:ok, transcript} ->
        html = transcript.html || ""
        parsed = engine.parse(html)

        Diagnostic.log("Landed:    #{transcript.url}")
        Diagnostic.log("Title:     #{transcript.title}")
        Diagnostic.log("Document:  #{byte_size(html)} bytes")
        Diagnostic.log("Section:   #{byte_size(transcript.markdown)} bytes of Markdown")
        Diagnostic.log("engine.blocked?(html): #{engine.blocked?(html)}")
        Diagnostic.log("engine.gated?(html):   #{engine.gated?(html)}")
        Diagnostic.log("engine.parse(html):    #{length(parsed)} raw results")

        Diagnostic.log(
          "Transcript links:      #{length(transcript.links)} (these are what harvest sees)"
        )

        Diagnostic.log("")
        Diagnostic.log("Raw results from engine.parse/1:")

        if parsed == [] do
          Diagnostic.log("- (none)")
        else
          for result <- Enum.take(parsed, 25),
              do: Diagnostic.log("- #{result.url}")
        end

        Diagnostic.log("")
        Diagnostic.log("Transcript link hosts:")

        if transcript.links == [] do
          Diagnostic.log("- (none)")
        else
          for {host, count} <- Enum.take(Diagnostic.hosts(transcript.links), 15),
              do: Diagnostic.log("- #{count} x #{host}")
        end

        Diagnostic.log("")
        {task, transcript}

      {:error, reason} ->
        Diagnostic.log("Page failed: #{inspect(reason)}")
        Diagnostic.log("")
        {task, nil}
    end
  end

# Stage 3: harvest each open transcript and record every decision.
Diagnostic.log("## 3. harvest, per decision")
Diagnostic.log("")

decisions =
  for {task, transcript} <- transcripts, transcript != nil do
    engine = task.engine
    label = "#{Neuron.Search.engine_id(engine)}: #{task.query}"

    case Neuron.Search.wall_reason(transcript) do
      reason when is_binary(reason) ->
        Diagnostic.log("### #{label}")
        Diagnostic.log("SKIPPED by Neuron.Search.wall_reason/1: #{reason}")
        Diagnostic.log("")
        {engine, :skipped, []}

      nil ->
        Diagnostic.log("### #{label}")

        case Neuron.Search.Harvest.harvest(transcript, model_opts) do
          {:ok, []} ->
            Diagnostic.log("HARVESTED 0 URLs. The model found nothing worth ingesting.")
            Diagnostic.log("")
            {engine, :harvested_nothing, []}

          {:ok, results} ->
            Diagnostic.log("HARVESTED #{length(results)} URLs:")

            for result <- results do
              prospect? = Neuron.ContactPolicy.prospect_source?(result.url)
              seller? = Neuron.Knowledge.domain(result.url) == seller_profile.domain

              verdict =
                cond do
                  not prospect? -> "REJECTED, not a prospect source"
                  seller? -> "REJECTED, seller's own domain"
                  true -> "ACCEPTED"
                end

              Diagnostic.log("- #{verdict}: #{result.url}")
              Diagnostic.log("    model reason: #{result.reason}")
            end

            Diagnostic.log("")
            {engine, :harvested, results}

          {:error, reason} ->
            Diagnostic.log("HARVEST FAILED: #{inspect(reason)}")
            Diagnostic.log("")
            {engine, :harvest_failed, []}
        end
    end
  end

# Stage 4: the ingestion decision the pipeline would actually make.
Diagnostic.log("## 4. what the pipeline would ingest")
Diagnostic.log("")

accepted =
  decisions
  |> Enum.flat_map(fn {_engine, _outcome, results} -> results end)
  |> Enum.uniq_by(& &1.url)
  |> Enum.filter(&Neuron.ContactPolicy.prospect_source?(&1.url))
  |> Enum.reject(&(Neuron.Knowledge.domain(&1.url) == seller_profile.domain))

for result <- accepted, do: Diagnostic.log("- #{result.url}")
if accepted == [], do: Diagnostic.log("- (nothing)")

Diagnostic.log("")
Diagnostic.log("## Summary")
Diagnostic.log("")

for {engine, outcome, results} <- decisions do
  Diagnostic.log(
    "- #{Neuron.Search.engine_id(engine)}: #{outcome}, #{length(results)} harvested"
  )
end

Diagnostic.log("")
Diagnostic.log("Ingestion children this round would spawn: #{length(accepted)}")
