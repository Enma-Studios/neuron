# Neuron

Neuron is the durable OTP core for Neureni's agentic GTM workflows. It runs
coordinators and delegated agents as `gen_statem` processes, keeps execution
state in Mnesia, and publishes domain facts to Dgraph through a retryable
outbox.

## Development

The project targets Elixir 1.20 and OTP 29. Copy credentials into your local
environment (never into config files):

```sh
export ZAI_API_KEY=...
export BROWSER_USE_API_KEY=...
```

Local Chromium is the preferred browser. Browser Use is selected after a
recorded local blockage. Configure both providers and the Dgraph endpoint in
`config/runtime.exs` or application configuration.

Z.AI requests are pinned to `glm-5.3-flash`; no alternate model is accepted.

Pinocchio is fetched from the private GitHub repository over SSH. The local
browser uses `/usr/bin/chromium` by default; set `CHROMIUM` for another binary.

The default execution store requests the `mnesia_rocksdb` backend. Enable its
native dependency on a C++ build host with `NEURON_ENABLE_ROCKSDB=true mix
deps.get`; otherwise startup logs an explicit warning and uses Mnesia
`disc_copies`. Production deployments should provision the RocksDB NIF and a
persistent `NEURON_DATA_DIR`.

Enable the local Bumblebee/Nx embedding stack with
`NEURON_ENABLE_LOCAL_ML=true mix deps.get`; it requires a C++ toolchain for
EXLA. The embedding contract remains available without that optional stack.

## Public API

```elixir
{:ok, run_id} = Neuron.start_run(Neuron.Coordinator.Default, %{goal: "find fintech prospects"})
{:ok, agent_id} = Neuron.spawn_agent(run_id, :enrich, Neuron.Agent.Echo, %{company: "Acme"})
Neuron.get_run(run_id)
Neuron.get_agent(agent_id)
Neuron.events(run_id)
Neuron.cancel_run(run_id)

# End-to-end web exploration and fit scoring
Neuron.start_run(Neuron.Coordinator.Intelligence, %{
  urls: ["https://example.com"],
  fit_profile: %{requirements: [%{category: "industry", description: "fintech"}]}
})
```

Coordinator and agent modules implement behaviours, so a profile can delegate
specialized discovery, browser extraction, graph reconciliation, and report
assembly without changing the runtime. Prompt templates are rendered with
`Neuron.Prompt.render/3` or `render_file/3` and their versions and input hashes
are emitted in telemetry.

The versioned Dgraph ontology models organizations, people, social accounts,
posts, clients and client profiles, geographies, requirements, leniencies,
evidence, campaigns, and fit profiles. UID edges connect people to employers,
organizations to staff and clients, accounts to owners and posts, and every
assertion back to its source evidence. Descriptive fields and post content have
full-text/term/trigram indexes; every searchable node can carry a cosine HNSW
embedding for semantic and hybrid retrieval.

`Neuron.Lead.evaluate/3` returns the score, selected flag, matched evidence,
and a reason for every requirement, geography decision, and final selection.
`Neuron.Coordinator.Intelligence` wires browser fetch, HTML-to-Markdown
cleanup, embedding, fit scoring, and durable outbox publication into one
parallelizable run.

`Neuron.Search.DuckDuckGo` performs search through Browser Use's browser
session, so search pages follow the same traceable fetch and snapshot path as
direct source URLs. `Neuron.Intelligence.discover/3` searches first and then
explores the returned links in parallel.

## Traceability

Every side effect emits `[:neuron, ...]` telemetry with `trace_id`, `run_id`,
`agent_id`, `task_id`, `operation_id`, and attempt metadata where available.
Events cover state transitions, model requests and visible tool decisions,
web-search results, browser provider attempts and blockages, snapshot cleanup,
embedding calls, Mnesia transactions, outbox delivery, and Dgraph queries or
mutations. Payloads are SHA-256 summaries by default; set
`config :neuron, telemetry: [capture_payloads: true]` only in controlled
environments.

The trace layer does not capture hidden chain-of-thought. It records the
model-visible reasoning field when returned, tool calls, decisions, inputs,
outputs, and durable state changes so an entire run can be reconstructed.

## Checks

Run the deterministic tests with `mix test`. The optional Dgraph integration
check provisions Dgraph v25.4.0 in Podman, waits for its health endpoint, and
then runs the tagged test:

```sh
scripts/dgraph_integration.sh
```

Live Z.AI and Browser Use checks are opt-in and require credentials.
