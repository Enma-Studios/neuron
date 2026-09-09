# Library guide

Neuron is an OTP application intended to sit behind a Phoenix controller
plane. Start the application normally and keep request state in the public
run APIs; Mnesia and Dgraph are managed by the supervision tree.

## Public run API

`Neuron.start_run/3` starts an asynchronous `gen_statem` and returns
`{:ok, id}`. `Neuron.get_run/1`, `Neuron.list_runs/0`, and `Neuron.events/1`
inspect durable state. `Neuron.cancel_run/1` stops a live run and
`Neuron.resume_run/1` re-admits an unfinished one.

`Neuron.run/3` starts a run and waits for a terminal response. Its response
contains `result` and exposes `leads`, `people`, `posts`, `organization`,
`campaign`, and `target_profile` at the top level when available.
`Neuron.await_run/2` provides the same envelope for an existing ID.
`Neuron.provide_run/2` supplies answers to a run paused in `:needs_input`.

## Campaign API

`Neuron.Campaign.questions/0` returns exactly eight bounded intake questions.
`Neuron.Campaign.question_prompt/1` formats only unanswered required fields.
`Neuron.Campaign.intake/2` accepts answers or a URL. A URL is browsed,
converted to Markdown, and passed to Z.AI for extraction. Unknown fields are
returned as prompts. Multiple distinct campaign proposals return
`{:approval_required, details}`; approve them with `Neuron.Campaign.approve/2`
and run several with `Neuron.Campaign.run_many/2`.

`Neuron.Campaign.run/2` owns the requested unique lead count outside the model.
It runs independent research attempts, deduplicates by company email, profile
URL, or person name, and returns `{:ok, %{status: :target_met, leads: ...}}`.
`max_attempts` bounds retries; an unmet target returns partial leads and errors.
`Neuron.Coordinator.Campaign` exposes this flow through `gen_statem`.

## Research and intelligence

`Neuron.Research.run/3` composes DuckDuckGo discovery, source ranking, browser
fetches, Htmd snapshots, Z.AI extraction, re-enrichment, outreach drafting,
Ecto validation, embeddings, and a Dgraph outbox write.

`Neuron.Intelligence.explore/3` processes one URL and a fit decision;
`explore_many/3` bounds parallel URLs; `discover/3` searches and explores
returned links. `Neuron.Lead.evaluate/3` returns score, selection, reasons,
and matched evidence. Requirements contribute 80% and geography 20%.

## Providers

`Neuron.Browser.fetch/2` tries local Pinocchio/Chromium first and falls back to
Browser Use on blockage. `Neuron.Search.DuckDuckGo.search/2` always uses
Browser Use for DuckDuckGo HTML. `Neuron.Model` and `Neuron.Embedding` are
provider behaviours; `Neuron.Model.ZAI` is the supported live model and
`Neuron.Model.Stub` is used by tests. Browser adapters implement `fetch/2`.

## Snapshots, schemas, and graph

`Neuron.Snapshot.from_html/2` removes executable/boilerplate markup and returns
Htmd Markdown plus a SHA-256 hash and extraction version. `Neuron.Schemas`
contains Ecto embedded contracts for social accounts, people, leads, research
results, and campaign results. `sanitize_research/1`, `validate_research/1`,
and `validate_campaign_result/1` normalize and enforce output shapes.

If normalized research fails validation, the model receives the output and
changeset errors through `confirm_output.eex` for one bounded repair pass.

`Neuron.Graph.Schema` versions the Dgraph ontology; `Neuron.Graph.upsert/2`
publishes facts and `query/3` executes DQL. `Neuron.GraphSearch` provides
lexical, semantic, hybrid, profile, and fit-profile helpers. Organizations,
people, posts, social accounts, clients, capabilities, requirements,
leniencies, assertions, snapshots, campaigns, and leads are graph entities.

## Durability and extension

`Neuron.Storage` owns Mnesia runs, agents, operations, ordered events, and
outbox records. `Neuron.Outbox.enqueue/3` is deterministic and retries until
Dgraph accepts the domain mutation. `Neuron.Recovery` re-admits unfinished
runs when enabled.

Implement `Neuron.Coordinator` (`plan/2`, `run/2`) for a workflow and
`Neuron.Agent.Worker` (`run/2`) for delegated work. Use `Neuron.spawn_agent/5`
for parallel or nested agents. Every operation carries run, agent, task, and
trace identifiers.

Attach ordinary Telemetry consumers to `[:neuron, ...]` events. Payloads are
summarized by default. `session_transcript: path` or
`NEURON_SESSION_TRANSCRIPT` records model-visible prompts, responses, and tool
calls; hidden chain-of-thought is never persisted.
