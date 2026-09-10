# Handoff: feat/neuron-05 usage and errors

## Context

Neureni issues #8 and #40. `get_run/1` returned no usage, no tokens and no cost, confirmed by
the spike dumping the whole snapshot: the top-level keys were exactly `error`, `id`, `input`,
`leads`, `opts`, `plan`, `profile`, `result`, `stage_data`, `stage_index`, `status`,
`version`. Telemetry could not substitute, because it undercounts browser sessions by half
and by no constant ratio. So the host had no honest source for what a run cost, from either
side, and the spike enforced its dollar cap by polling Browser Use's own API instead.

A failed run also carried only a raw error term, so the host could not render a cause.

## What changed, all additive

`get_run/1` gains `usage`, always present, and `error_class`, present only when the run
carries an error. No existing key changed shape.

```elixir
%{
  usage: %{
    models:  [%{label: "glm-5.3-flash", model_calls: 3, prompt_tokens: 1250, completion_tokens: 170, ...}],
    browser: [%{label: "browser_use", browser_sessions: 2, browser_seconds: 16.5, ...}],
    by_stage: %{"plan_search" => %{...}, "search" => %{...}},
    total: %{model_calls: 3, prompt_tokens: 1250, completion_tokens: 170,
             browser_sessions: 2, browser_seconds: 16.5}
  },
  error_class: :search
}
```

- `Neuron.Usage`, with `record_model/2`, `record_browser/2`, `snapshot/1` and
  `error_class/1`, over a new `neuron_usage` table, migration `20260910000001`.
- `Neuron.Model.ZAI` records prompt and completion tokens with the model id on every
  successful completion.
- `Neuron.Browser.BrowserUse` stamps the opening run, stage and provider on the session
  handle and records the session's seconds when it stops. The handle carries that context
  because after #44 the process that stops a session is often not the one that opened it.
- `Neuron.StageWorker` puts the stage name into the options every call downstream already
  receives, which is what makes per-stage attribution possible without threading a new
  argument through the pipeline.
- `Neuron.Telemetry.trace_metadata/1` carries `:stage` alongside the other correlation keys.

## Why SQL rather than memory or telemetry

A stage is one Oban job in its own process. Nothing survives from the stage that made a call
to the caller that later asks what the run cost, so the record has to be durable. Telemetry
was already proven unable to do this job by #40.

Rows carry `parent_run_id`, so a campaign's totals include the ingestion children it
dispatched rather than only the parent's own calls. A campaign's cost is the cost of its
tree, and `snapshot/1` sums it in one query.

Usage accounting must never be the reason a run fails, so a row that cannot be written is
emitted as `[:neuron, :usage, :dropped]` telemetry and abandoned.

## Verified against the real provider

The token counts are not assumed. One live call through `Neuron.Model.ZAI.complete/2`
returned `usage` with `prompt_tokens: 19` and a `completion_tokens` whose
`completion_tokens_details.reasoning_tokens` was most of it. That last part is worth knowing
for cost: at the configured `reasoning_effort`, completion tokens are mostly reasoning
tokens. `docs/library.md` says so.

The first probe of this returned no `usage` key at all, which looked like a serious problem
until it turned out the probe had sent `reasoning_effort: "minimal"`, which production never
sends. The production request body returns usage every time.

## Tests

`test/neuron_usage_test.exs`, six cases:

- **a fixture run reports non-zero usage per stage and in total**, the acceptance case,
  including an ingestion child whose spend is attributed to the campaign that dispatched it
- a run with no recorded calls reports zeroed usage rather than a missing key, and carries no
  `error_class`
- `error_class/1` over seven real error shapes taken from actual runs, including the
  `Dlex.Error` seen in the #43 acceptance run and the `:search_unavailable` from #41
- an unrecognised error is `:unknown`, and no error has no class
- two failed fixture runs read the right class off `get_run/1`

Full suite: 85 passed, 3 excluded, from a clean database so the new migration is exercised.
`mix format --check-formatted` clean.

## Not covered

- **`:budget` never fires.** The class exists so the host's enum is exhaustive, but nothing
  raises it: the cost cap in `neuron-05`'s original acceptance is not implemented and was not
  in the scope given for this branch. Usage is now recorded, which is the thing a cap would
  need.
- **No money.** Tokens and seconds are counted; they are not priced. Converting either into a
  currency amount needs a rate table, and putting a vendor's prices in library code is a
  decision, not an implementation detail.
- **Session counts are Neuron's own, not the provider's.** #40 asks for a count matching
  Browser Use's own. This counts every session Neuron opened and closed, which after #44 is
  every session it causes. If those still disagree with the provider's billing, the gap is
  now measurable from both ends rather than only one.
