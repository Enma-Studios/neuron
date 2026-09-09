# Architecture

Neuron is an OTP boundary between transient agent execution and durable domain
knowledge. The application owns processes and recovery; Dgraph owns facts
that are useful to search and relate across runs.

## Supervision tree

```text
Neuron.Supervisor
├── Neuron.Storage       Mnesia schema, tables, transactions
├── Neuron.Dgraph        Dlex connection boundary
├── Neuron.Outbox        retrying domain publisher
├── Neuron.RunRegistry   unique run and agent names
├── Neuron.RunSupervisor dynamic coordinator processes
├── Neuron.AgentSupervisor dynamic delegated workers
└── Neuron.Recovery      re-admission of unfinished runs
```

Pinocchio is an OTP dependency. Its own supervisor owns the browser pool;
Neuron does not duplicate that pool. A Browser Use fallback session is
provider-owned and is stopped after the fetch.

## Run lifecycle

`Neuron.Run` uses `:gen_statem` state functions:

```text
queued → planning → executing → complete
                  └───────────→ failed
queued/planning/executing ─────→ cancelled
planning ──────────────────────→ needs_input → planning
```

Each transition writes the run record and an event before moving on. Model,
browser, embedding, and coordinator operations are recorded in the operation
table when they are part of a run. Delegated workers use the same pattern and
carry `run_id`, `agent_id`, and optional `parent_id`.

## Data boundaries

Mnesia contains operational state: runs, agents, operations, ordered events,
and outbox entries. Dgraph contains organizations, people, posts, accounts,
requirements, evidence, campaign profiles, and other domain facts. The outbox
prevents a Dgraph outage from destroying the local execution record.

The graph schema is versioned in `Neuron.Graph.Schema`. Schema application is
idempotent for the declared predicates and types; deployment tooling should
run it against the target Dgraph endpoint before publishing domain facts.

Campaign orchestration sits above individual research attempts. Intake may
pause for user answers or approval of multiple URL-derived proposals. The
campaign layer owns the requested lead count, deduplicates attempts, and
publishes a Campaign node linked to selected leads.

## End-to-end discovery

`Neuron.Intelligence.discover/3` composes the providers as follows:

```text
query
  │
  ▼
DuckDuckGo HTML search ── Browser Use provider
  │
  ▼
ranked URLs
  │  Task.async_stream (bounded concurrency)
  ▼
local Chromium / Pinocchio ── on blockage ── Browser Use / Pinocchio
  │
  ▼
Htmd Markdown snapshot → embedding → transparent fit decision → outbox
```

The search provider is deliberately separate from the Z.AI model provider.
Z.AI completion remains available for agent reasoning and is pinned to
`glm-5.3-flash`; web search is browser-backed DuckDuckGo.

## Fit decision model

`Neuron.Lead.evaluate/3` produces a decision map rather than a bare boolean.
For each requirement it records the criterion, match status, and excerpt. It
adds a geography decision and a final threshold explanation. The current
score is:

```text
score = (matched_requirements / total_requirements) * 0.8
      + geography_match * 0.2
```

An empty requirement list scores the requirement component as `1.0`, and an
empty preferred geography list scores the geography component as `1.0`.

## Trace context

Callers can supply `trace_id`, `run_id`, `agent_id`, `task_id`,
`operation_id`, and `attempt` as keyword options. Boundary modules preserve
these fields in telemetry and database transaction spans. Payloads are
summarized by default, allowing trace correlation without recording secrets or
large HTML bodies in the event stream.

Research output is checked with Ecto after normalization. A failed shape check
causes one model confirmation/repair pass with the validation errors before the
run can publish to Dgraph.
