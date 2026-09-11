# One trial of the layered-context experiment. Runs the campaign once and
# writes a JSON record of everything the report needs.
#
#   ARM=layered TRIAL=1 mix run scripts/layered_context_trial.exs
#   ARM=baseline TRIAL=1 mix run scripts/layered_context_trial.exs
#
# `baseline` sets layered_context: false, which reproduces v0.2.1's message
# assembly exactly, so the two arms differ in one option and nothing else.

arm = System.get_env("ARM", "layered")
trial = System.get_env("TRIAL", "1")
out = System.get_env("OUT", "/tmp/trial-#{arm}-#{trial}.json")

engines = [Neuron.Search.DuckDuckGo, Neuron.Search.Yandex]

input = %{
  organization: "Enma Studios",
  field:
    "Software product studio building custom software, product builds, rebuilds and extensions for companies without engineering capacity",
  offer:
    "A small senior team that builds, rebuilds or extends your product when you have something to ship and no engineering capacity to ship it. Faster and cheaper than an agency, less risky than a freelancer.",
  target_roles: ["Founder", "Co-founder", "CTO", "Head of Product", "Product lead"],
  target_organizations: [
    "Companies with 10 to 80 people and fewer than five engineers",
    "Companies with a product or internal tool to build, rebuild or extend",
    "Companies with open engineering roles they cannot fill"
  ],
  geography: nil,
  exclusions: nil,
  lead_count: 1
}

# The overlays a host would supply. Identical across every trial so the
# prefix is comparable, and never assembled by Neuron itself.
tenant_overlay = %{
  "account" => "Enma Studios",
  "forbidden_claims" => [
    "do not claim an existing relationship, introduction or referral",
    "do not claim a named client without evidence in the campaign brief"
  ],
  "prior_decisions" => [
    "outreach is email first; other channels are drafts only",
    "no contact with branch offices of an existing customer"
  ],
  "tone" => "plain, specific, no superlatives"
}

campaign_overlay = %{
  "campaign" => "dogfood outbound, autumn 2026",
  "lead_target" => 1,
  "suppressions" => ["anyone already contacted under a previous Enma campaign"]
}

bounds = [
  organization_id: "layered-context-#{arm}",
  channels: ["email"],
  lead_count: 1,
  engines: engines,
  sessions: 1,
  pages_per_session: 3,
  max_rounds: 2,
  searches_per_round: 4,
  max_queries: 8,
  max_pages: 6,
  batch_size: 3,
  budget_seconds: 600,
  harvest_concurrency: 2,
  require_contact_channel: false
]

opts =
  case arm do
    "baseline" ->
      Keyword.put(bounds, :layered_context, false)

    _ ->
      bounds
      |> Keyword.put(:layered_context, true)
      |> Keyword.put(:tenant_overlay, tenant_overlay)
      |> Keyword.put(:campaign_overlay, campaign_overlay)
  end

defmodule Trial do
  def graph(query) do
    {:ok, result} = Neuron.Graph.query(query, %{}, [])
    result
  end

  def count(type) do
    case graph("{ q(func: type(#{type})) { total: count(uid) } }") do
      %{"q" => [%{"total" => total}]} -> total
      _ -> 0
    end
  end

  # An excerpt is verbatim when it appears in the Markdown of a document
  # this run ingested. Whitespace is normalized on both sides, because the
  # extraction rewraps lines; nothing else is relaxed.
  #
  # The check is against the whole ingested corpus rather than the source
  # the assertion cites, because assertions carry no `sources` edge: see
  # `with_source_edge`, which is reported so the weaker check is visible
  # rather than quietly assumed.
  def verbatim do
    %{"assertions" => assertions} =
      graph("{ assertions(func: type(Assertion)) { excerpt sources { uid } } }")

    %{"snapshots" => snapshots} =
      graph("{ snapshots(func: type(Snapshot)) { uid markdown } }")

    corpus = Enum.map_join(snapshots, "\n", &normalize(&1["markdown"] || ""))

    checked =
      for assertion <- assertions,
          excerpt = normalize(assertion["excerpt"] || ""),
          excerpt != "",
          do: String.contains?(corpus, excerpt)

    %{
      checked: length(checked),
      passed: Enum.count(checked, & &1),
      rate: if(checked == [], do: nil, else: Enum.count(checked, & &1) / length(checked)),
      with_source_edge: Enum.count(assertions, &(&1["sources"] not in [nil, []])),
      total_assertions: length(assertions)
    }
  end

  defp normalize(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  def browser_cost do
    key = System.get_env("BROWSER_USE_API_KEY")

    case Req.get("https://api.browser-use.com/api/v4/browsers?pageSize=100",
           headers: [{"x-browser-use-api-key", key}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        Map.new(items, fn item ->
          {item["id"],
           %{
             started_at: item["startedAt"],
             cost: to_float(item["proxyCost"]) + to_float(item["browserCost"])
           }}
        end)

      _ ->
        %{}
    end
  end

  defp to_float(nil), do: 0.0
  defp to_float(value) when is_number(value), do: value / 1

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> 0.0
    end
  end
end

# Fresh graph data per trial, schema retained.
{:ok, _} =
  Req.post("http://localhost:18080/alter",
    json: %{"drop_op" => "DATA"},
    receive_timeout: 60_000
  )

Process.sleep(2_000)
before_browsers = Trial.browser_cost()
started = System.monotonic_time(:millisecond)

{:ok, id} = Neuron.start_run(Neuron.Coordinator.Campaign, input, opts)
IO.puts("#{arm} trial #{trial}: run #{id}")

deadline = System.monotonic_time(:millisecond) + 1_500_000

wait = fn wait, provided? ->
  run = Neuron.get_run(id)

  cond do
    run.status in [:complete, :failed, :cancelled] ->
      run

    run.status == :needs_input and not provided? ->
      Neuron.provide_run(id, input)
      Process.sleep(1_000)
      wait.(wait, true)

    System.monotonic_time(:millisecond) > deadline ->
      run

    true ->
      Process.sleep(5_000)
      wait.(wait, provided?)
  end
end

run = wait.(wait, false)
elapsed = (System.monotonic_time(:millisecond) - started) / 1000
after_browsers = Trial.browser_cost()

new_browsers =
  after_browsers
  |> Enum.reject(fn {id, _} -> Map.has_key?(before_browsers, id) end)
  |> Enum.map(fn {_, value} -> value.cost end)

leads = (is_map(run[:result]) && run.result[:leads]) || []

record = %{
  arm: arm,
  trial: trial,
  run_id: id,
  status: run.status,
  error: inspect(run[:error]),
  elapsed_seconds: Float.round(elapsed, 1),
  usage: run.usage,
  browser_cost_usd: Float.round(Enum.sum(new_browsers), 4),
  browser_sessions_billed: length(new_browsers),
  result_status: is_map(run[:result]) && run.result[:status],
  stop_reason: is_map(run[:result]) && run.result[:stop_reason],
  summary: is_map(run[:result]) && run.result[:summary],
  returned_count: length(leads),
  failures: (is_map(run[:result]) && run.result[:failures]) || [],
  graph: %{
    organizations: Trial.count("Organization"),
    people: Trial.count("Person"),
    sources: Trial.count("Source"),
    snapshots: Trial.count("Snapshot"),
    assertions: Trial.count("Assertion"),
    evidence: Trial.count("Evidence"),
    leads: Trial.count("Lead")
  },
  verbatim: Trial.verbatim(),
  leads:
    Enum.map(leads, fn lead ->
      %{
        person_name: lead[:person_name],
        title: lead[:title],
        organization: lead[:organization],
        observed_email: lead[:observed_email],
        preferred_channel: lead[:preferred_channel],
        fit_score: lead[:fit_score],
        reason: lead[:reason],
        outreach: lead[:outreach] && %{channel: lead.outreach.channel, subject: lead.outreach.subject, body: lead.outreach.body}
      }
    end)
}

File.write!(out, Jason.encode!(record, pretty: true))
IO.puts("#{arm} trial #{trial}: #{run.status} in #{Float.round(elapsed, 1)}s -> #{out}")
IO.puts("  orgs #{record.graph.organizations} sources #{record.graph.sources} claims #{record.graph.assertions} leads #{record.returned_count}")
IO.puts("  tokens #{record.usage.total.prompt_tokens}p/#{record.usage.total.cached_tokens}c/#{record.usage.total.completion_tokens}o over #{record.usage.total.model_calls} calls")
IO.puts("  browser #{record.browser_sessions_billed} sessions $#{record.browser_cost_usd}")
