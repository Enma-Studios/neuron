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

For a durable multistep pipeline, also export `stages/0` (ordered atom names) and `stage/3`. Each stage receives its predecessor's saved data and run options and returns `{:ok, next_data}` or `{:error, reason}`. The final stage's value becomes `result`. `Neuron.Coordinator.LeadGeneration` demonstrates the production contract. Stage code must tolerate replay; a checkpoint cannot atomically commit a remote HTTP request.

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

`Neuron.Campaign.run/2` counts unique contacts outside the model, retains failures, and stops when the target is met or its attempt budget is exhausted. Every campaign run and research attempt receives its own UUID; attempts are correlated with the campaign through `parent_run_id`. `Neuron.Research.run(domain, fit_profile, opts)` starts/awaits a durable six-stage research run. An explicit `run_id:` identifies an existing attempt on replay. Research produces organization, people, posts, leads, drafts, target profile, and source URLs; `Neuron.Schemas` validates shapes with embedded Ecto schemas and changesets.

`Neuron.Intelligence.explore/3` is a lower-level browser/snapshot/embedding/scoring API. `explore_many/3` and `discover/3` operate over multiple sources. Use the coordinator profile to run this work durably.

## Boundaries

`Neuron.Graph.upsert/2` writes domain facts with stable external identities; `query/3` accepts DQL and variables. `Neuron.Graph.Schema.definition/0` exposes the complete domain schema. Dgraph owns full-text/vector querying and relationship traversal.

`Neuron.Browser.fetch/2`, `Neuron.Search.web/2`, `Neuron.Snapshot.from_html/2`, `Neuron.Embedding`, and `Neuron.Model` define the source/model boundaries. `Neuron.Prompt.render/3` and `render_file/3` render EEx with `@assign` values and persist raw rendered prompts for correlated runs. Prompt files ship in the application's `priv` directory.

`Neuron.ContactPolicy` supplies evidence/contact rules and advisory source preferences. `Neuron.Lead.evaluate/3` returns explicit selection reasons and criterion evidence. These rules are configurable application logic, not proof that every extracted assertion is true.
