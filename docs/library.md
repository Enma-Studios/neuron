# Library API

## Runs

- `Neuron.start_run(profile, input, opts \\ [])` returns `{:ok, id}` after the initial machine, event, and job commit.
- `Neuron.run(profile, input, opts \\ [])` starts and awaits a run.
- `Neuron.get_run(id)` returns saved input, profile, state (`status`), version, output (`result`), and error. Available lead/profile fields are also exposed at the top level. Missing IDs raise `Ecto.NoResultsError`. **It never writes**, so a poller can look at a live run as often as it likes without changing it.
- `get_run/1` also returns `usage`, and `error_class` when the run carries an error. Both are additive; no existing key changed shape.

`usage` is `%{models: [...], browser: [...], by_stage: %{...}, total: %{...}}`. Every entry counts `model_calls`, `prompt_tokens`, `completion_tokens`, `browser_sessions`, `browser_seconds` and `graph_conflicts`; `models` groups by model id and `browser` by provider, each under `label`. `by_stage` is keyed by the stage name that spent it, so a stage that fires per source accumulates across its runs. Totals include the ingestion children the run dispatched, not only its own calls, because a campaign's cost is the cost of its tree. Usage is recorded in SQL as it is spent, since each stage is a separate Oban job in its own process. Note that `completion_tokens` includes the model's reasoning tokens, which is most of them at the configured `reasoning_effort`.

`graph_conflicts` counts graph writes that lost their entity to a concurrent writer and ran out of retries. A Dgraph transaction abort is retried with bounded exponential backoff, so a conflict the retry absorbs costs time rather than data and is not counted; only an exhausted one is. A run with a non-zero count completed having lost evidence it had already gathered, and should be read that way. `graph_conflict_attempts` (5) and `graph_conflict_backoff_ms` (50, doubling to a cap of 800 with jitter) are per-run options.

`error_class` is `:storage`, `:model`, `:browser`, `:budget`, `:search`, or `:unknown`, and is absent when there is no error. An error shape Neuron does not recognise classifies as `:unknown` rather than being guessed into the nearest familiar bucket. Nothing raises `:budget` today: it is reserved for a cost cap, which is not implemented.
- `Neuron.await_run(id, timeout \\ 120_000)` returns `{:ok, snapshot}`, `{:needs_input, snapshot}`, `{:error, snapshot}`, or `{:error, :timeout}`. Waiting polls SQL; use asynchronous IDs from web requests.
- `Neuron.provide_run(id, input)` merges supplied answers and resumes a run waiting for input.
- `Neuron.cancel_run(id)` commits cancellation. Already-running external requests may finish, but their stale version cannot advance the run.
- `Neuron.resume_run(id)` resumes a failed pipeline from its checkpoint or replans an ordinary coordinator.
- `Neuron.reconcile_run(id)` reflects a discarded or cancelled current worker job as a failed run, then returns the same snapshot `get_run/1` returns. This is a **write**: call it when something must act on a run that may have been abandoned, not when merely displaying one.

`get_run/1` used to reconcile as a side effect, so every read of a live run could fail it. It no longer does. `await_run/2` and `resume_run/1` still reconcile, because waiting and resuming are not reading: a run whose worker was discarded has to be noticed or `await_run/2` would spin until its timeout. A caller that wants the old behaviour calls `reconcile_run/1` in place of `get_run/1`.
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

`Neuron.Campaign.intake/2` normalizes user details and optionally scrapes a website. **Scraping fills answers that are missing; it is not a precondition for answers that were supplied.** A caller who answered every question gets a campaign even when the URL cannot be fetched or parsed, and a caller who answered some is asked only for the rest, never for the whole set again.

A scraped campaign also carries its evidence. `source_markdown` is the cleaned Markdown of the seller's page, returned once so a host that never reads Dgraph can retain it, and `source_url` is where it came from. `field_sources` maps each scraped key to `%{excerpt:, source_url:}`, where the excerpt is the page's own bytes: every quote the model returns is anchored back into `source_markdown` and re-sliced from it, so a quote that differs only in whitespace is relocated and one that is nowhere on the page is dropped rather than returned as evidence. The fields themselves are unchanged summaries; the excerpt is additional.

When a scrape does fail, the reason names the step that failed as `{step, reason}` on `scrape_error`: `:fetch`, `:html`, `:normalize`, `:save_document`, `:prompt`, `:model` or `:decode`. Only `:fetch` means the URL was the problem. `questions/0` provides the eight-field intake definition. Missing details and multiple campaign proposals are explicit tagged results. `approve/2` accepts all or zero-based selection indexes. `run_many/2` runs approved campaigns separately.

After explicit proposal approval, start `Neuron.Coordinator.Campaign` with `%{approved_campaign: campaign}` to validate the approved brief without inferring new proposals. Callers are responsible for presenting proposals and obtaining that approval.

`Neuron.Campaign.run/2` starts and awaits the durable campaign pipeline and returns the standard run snapshot. The normalized brief separates `seller_profile` (our domain, offering, field, geography) from `target_profile` (prospective markets, roles, geography, exclusions). Keep its `campaign_id` when requesting new executions of the same campaign. Each execution and ingestion child has its own UUID.

Campaigns search for external prospects, ingest documents into the shared graph, and retrieve/rank graph candidates. Sourced, person-specific company emails rank first; verified LinkedIn, X and other professional social channels also qualify. GitHub is excluded from prospect discovery and outreach. Repeats are suppressed within the same campaign; other campaigns can use the same global facts. Reservations become delivered atomically with the completed SQL run; cancellation releases pending reservations and cancels known ingestion children. Failed executions retain reservations for resumption; cancel one to release them.

`require_contact_channel` decides whether a person Neuron cannot yet reach is a lead. It defaults to `true`, which withholds anyone without an observed company email or verified professional profile, and is the behaviour every existing caller gets. Set it to `false` when the caller resolves contacts itself: a person with a name, a title and a sourced employer is then returned as a lead with `observed_email: nil`, no `contact_channels`, no `preferred_channel` and no `outreach` draft, and everything else unchanged, including selection reasons, criterion evidence, score breakdown and the claims behind them. No email is ever invented under either setting; `observed_email` is null precisely when nothing was observed, and an email is only reported when it appears in a retained excerpt attributed to that person. A lead with no channel always ranks below one that has a way to reach it.

`observed_email` is the name the host uses. `email` carries the same value and is retained until `neuron-06` renames it.

`run.result.status` is `:target_met`, `:partial`, or `:no_qualified_leads`. Results include `campaign_id`, `campaign_run_id`, `target_count`, `returned_count`, `leads`, `summary`, `stop_reason`, `failures`, and `selection`.

A person must match the campaign on every check before they are scored: a sourced `name`; an observed `employer` at authority 0.8 or higher (`employer`), which is not the seller (`seller`); a title holding one of the target roles or titles as whole words (`role`); a location matching the target geography, when one is given (`geography`); and none of the exclusions in the person's facts or in their employer organization's name, description or industry (`exclusion`). The `exclusions` field is split into one term per clause on commas and semicolons, dropping a leading "not" or "no", so "Not agencies, not security vendors." becomes `["agencies", "security vendors"]`. Two gates read the employer organization when the campaign sets them: `target_profile.company_size` (`%{min, max}` employees, either bound optional) rejects an organization whose stated `employee_count` falls outside the range (`size`), and `target_profile.industries` rejects one whose industry and description contain none of the terms as whole words (`industry`). Both come from the intake fields `company_size` and `industries`. An organization that states no size, or no industry or description, passes the gate and is counted in `unknown_by`; nothing is inferred. A match then needs `fit_score` at or above `selection_threshold` (default 0.5; `fit_profile.threshold` is not used by campaign ranking) (`threshold`). Campaign roles are usually categories no title contains, so `:prepare` makes one model call to expand `target_profile.roles` into the concrete job titles a team page prints, kept as `target_profile.titles`.

`selection` accounts for the latest ranking pass: `%{considered, ranked, rejected, withheld_contact, rejected_by, unknown_by}`, where `rejected_by` counts, for each check above, the candidates that failed it (one candidate can fail several). `considered: 0` means nobody reached the scorer; `rejected > 0` with `ranked: 0` means people were scored and rejected, and `rejected_by` names the check. It is also on `stage_data.selection` while a run is in progress, so a cancelled run keeps it. `fit_score` is written to the graph only on delivered `Lead` nodes, so a run with no leads leaves none.

A degraded round and an unavailable search are different outcomes and are reported differently. An engine that hits a login gate, a consent wall or a bot check is a skipped engine: the round continues on whatever other engines answered, the run completes, and the skip appears in `result.failures` as `%{engine, kind, query, reason}` with `kind` one of `:login_gate`, `:consent_wall`, `:bot_check`, `:page_failed` or `:harvest_failed`. A search is unavailable only when **every** enabled engine was actually attempted and failed; then the run fails and `run.error` is `{:search_unavailable, failures}` carrying the same entries, one per engine. An enabled engine that was never asked cannot be evidence that search is unavailable, so a round which reached only some of them is degraded rather than unavailable. So a completed run with non-empty `failures` is degraded, and a failed run with `:search_unavailable` is unavailable. Each lead includes graph identities, available contact channels, preferred channel, optional company email, score breakdown, semantic similarity, evidence, cited reason, and a channel-specific outreach draft. A lead returned under `require_contact_channel: false` with no observed channel has no recipient to address, so it carries its reason and `outreach: nil` instead of a draft. Zero leads is an unsuccessful research outcome even though the orchestration job completed normally. `summary` separates its two causes: "No companies matched the campaign criteria" when nothing fit, and "Companies matched the campaign criteria, but no contact channel was observed for any candidate" when people fit and were withheld for lack of a way to reach them. The second is what `require_contact_channel: false` turns into leads. Reaching the target stops new scheduling; the final batch can return extra qualifying leads.

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
