# Library API

## Runs

- `Neuron.start_run(profile, input, opts \\ [])` returns `{:ok, id}` after the initial machine, event, and job commit.
- `Neuron.run(profile, input, opts \\ [])` starts and awaits a run.
- `Neuron.get_run(id)` returns saved input, profile, state (`status`), version, output (`result`), and error. Available lead/profile fields are also exposed at the top level. Missing IDs raise `Ecto.NoResultsError`.
- `Neuron.await_run(id, timeout \\ 120_000)` returns `{:ok, snapshot}`, `{:needs_input, snapshot}`, `{:error, snapshot}`, or `{:error, :timeout}`. Waiting polls SQL; use asynchronous IDs from web requests.
- `Neuron.provide_run(id, input)` merges supplied answers and resumes a run waiting for input.
- `Neuron.cancel_run(id)` commits cancellation. Already-running external requests may finish, but their stale version cannot advance the run.
- `Neuron.resume_run(id)` resumes a failed pipeline from its checkpoint or replans an ordinary coordinator.
- `Neuron.reconcile_run(id)` reflects a discarded/cancelled current worker job as a failed run; inspection and resumption also perform this reconciliation.
- `Neuron.events(id)` returns SQL history ordered by event ID.
- `Neuron.list_runs()` returns saved machine snapshots. For large deployments, query the repository with application-specific pagination instead.
- `Neuron.spawn_agent(parent_id, role, worker, input, opts \\ [])` starts a separately durable delegated worker; `get_agent/1` and `cancel_agent/1` use the run APIs.

## Coordinator profiles

Implement `Neuron.Coordinator` with `plan(input, context)` and `run(plan, context)`. Both return `{:ok, value}` or `{:error, reason}`. Planning can additionally return `{:needs_input, details}` or `{:approval_required, details}`. Context includes `run_id`, `options`, and `plan`.

```elixir
defmodule MyProfile do
  @behaviour Neuron.Coordinator
  def plan(input, _context), do: {:ok, input}
  def run(plan, _context), do: {:ok, %{leads: plan.leads}}
end
```

For a durable multistep pipeline, also export `stages/0` (ordered atom names) and `stage/3`. Each stage receives its predecessor's saved data and run options and returns `{:ok, next_data}` or `{:error, reason}`. A stage may return `{:goto, stage_name, data}` to checkpoint a loop or `{:wait, seconds}` to release its worker until children finish. The final stage's value becomes `result`. `Neuron.Coordinator.LeadGeneration` demonstrates the production contract. Stage code must tolerate replay; a checkpoint cannot atomically commit a remote HTTP request.

Delegated workers implement `Neuron.Agent.Worker.run(input, context)`. They are ordinary separately queued jobs. Parent cancellation does not recursively cancel independent child runs.

## FSM definitions

```elixir
defmodule ReviewMachine do
  use Neuron.FSM
  state :waiting
  state :approved
  state :expired
  transition :approve, from: :waiting, to: :approved, guard: :authorized?
  transition :expire, from: :waiting, to: :expired
  def authorized?(_data, payload), do: payload[:approved] == true
end

{:ok, machine} = Neuron.FSM.create(ReviewMachine, %{})
Neuron.FSM.allowed_events(machine.id) # candidate events; guards evaluate on send
Neuron.FSM.schedule_event(machine.id, :expire, 86_400)
Neuron.FSM.send(machine.id, :approve, %{approved: true}, version: 0)
```

A `worker:` option schedules that Oban worker on transition. `after: {5, :seconds}` or `{24, :hours}` delays worker execution. Workers receive `machine_id` and `version` in their JSON args. Implement the same version check before work and conditional `send/4` after work as the built-in workers. `create/3` can schedule the initial worker with `worker:`. Guards are named functions on the definition, not closures. States must be declared before use; invalid definitions fail compilation.

Invalid events return `{:error, {:invalid_event, state, event}}`; stale versions return `{:error, :stale}`; rejected guards return `{:error, :guard_rejected}`. `state/1` returns the persisted state string; `data/1` decodes a fetched machine's operational payload.

## Campaigns and research

`Neuron.Campaign.intake/2` normalizes user details and optionally scrapes a website. `questions/0` provides the eight-field intake definition. Missing details and multiple campaign proposals are explicit tagged results. `approve/2` accepts all or zero-based selection indexes. `run_many/2` runs approved campaigns separately.

After explicit proposal approval, start `Neuron.Coordinator.Campaign` with `%{approved_campaign: campaign}` to validate the approved brief without inferring new proposals. Callers are responsible for presenting proposals and obtaining that approval.

`Neuron.Campaign.run/2` starts and awaits the durable campaign pipeline and returns the standard run snapshot. The normalized brief separates `seller_profile` (our domain, offering, field, geography) from `target_profile` (prospective markets, roles, geography, exclusions). Keep its `campaign_id` when requesting new executions of the same campaign. Each execution and ingestion child has its own UUID.

Campaigns search for external prospects, ingest documents into the shared graph, and retrieve/rank graph candidates. Sourced, person-specific company emails rank first; verified LinkedIn, X and other professional social channels also qualify. GitHub is excluded from prospect discovery and outreach. Repeats are suppressed within the same campaign; other campaigns can use the same global facts. Reservations become delivered atomically with the completed SQL run; cancellation releases pending reservations and cancels known ingestion children. Failed executions retain reservations for resumption; cancel one to release them.

`run.result.status` is `:target_met`, `:partial`, or `:no_qualified_leads`. Results include `campaign_id`, `campaign_run_id`, `target_count`, `returned_count`, `leads`, `summary`, `stop_reason`, and `failures`.

A degraded round and an unavailable search are different outcomes and are reported differently. An engine that hits a login gate, a consent wall or a bot check is a skipped engine: the round continues on whatever other engines answered, the run completes, and the skip appears in `result.failures` as `%{engine, kind, query, reason}` with `kind` one of `:login_gate`, `:consent_wall`, `:bot_check`, `:page_failed` or `:harvest_failed`. A search is unavailable only when **every** enabled engine failed; then the run fails and `run.error` is `{:search_unavailable, failures}` carrying the same entries, one per engine. So a completed run with non-empty `failures` is degraded, and a failed run with `:search_unavailable` is unavailable. Each lead includes graph identities, available contact channels, preferred channel, optional company email, score breakdown, semantic similarity, evidence, cited reason, and a channel-specific outreach draft. Zero leads is an unsuccessful research outcome even though the orchestration job completed normally. Reaching the target stops new scheduling; the final batch can return extra qualifying leads.

`Neuron.Research.run(domain, fit_profile, opts)` retains the standalone account-research API; it is separate from campaign prospect discovery. `Neuron.Ingestion.submit/2` accepts a URL or Markdown document and returns a durable run UUID. See [ingestion](ingestion.md) for its contracts.

Explicit assertions use `assertions: [%{entity_type: "Organization", identity: "example.org", predicate: "industry", value: "Software"}]`. They outrank scraped claims but do not substitute for sourced contact verification. `Neuron.Knowledge.assert_fact/2` supports independent assertions.

`Neuron.Intelligence.explore/3` is a lower-level browser/snapshot/embedding/scoring API. `explore_many/3` and `discover/3` operate over multiple sources. Use the coordinator profile to run this work durably.

## Boundaries

`Neuron.Graph.upsert/2` writes domain facts with stable external identities; `query/3` accepts DQL and variables. `Neuron.Graph.Schema.definition/0` exposes the complete domain schema. Dgraph owns full-text/vector querying and relationship traversal.

`Neuron.Browser.fetch/2`, `Neuron.Search.web/2`, `Neuron.Snapshot.from_html/2`, `Neuron.Embedding`, and `Neuron.Model` define the source/model boundaries. `Neuron.Prompt.render/3` and `render_file/3` render EEx with `@assign` values and emit rendered prompts through correlated telemetry. Prompt files ship in the application's `priv` directory.

`Neuron.ContactPolicy` supplies evidence/contact rules and advisory source preferences. `Neuron.Lead.evaluate/3` returns explicit selection reasons and criterion evidence. These rules are configurable application logic, not proof that every extracted assertion is true.

## Outreach channels

Lead `contact_channels` are ordered company email, LinkedIn, X, then other professional socials. `preferred_channel` selects the draft format. `outreach` contains `channel`, verified `recipient`, optional `subject`, and `body`. Email retains the convenience fields `email_subject` and `email_body`; these are null for social drafts. Missing email addresses are never guessed. GitHub is excluded.

Email uses a concise professional message; LinkedIn uses a connection note (300 characters), X a private-message draft (500 characters), and other socials a private introduction (600 characters). Subject lines are only valid for email. The model is asked to repair invalid channel/length output. Drafts never send or assume messaging permissions.
