# Neuron

[Neuron](https://github.com/Enma-Studios/neuron) is an embeddable Elixir agent library for Neureni. It runs campaign intake, research, evidence extraction, enrichment, contact qualification, and channel-specific outreach drafting. It returns leads and their selection reasons; it does not send messages.

Oban executes a durable state machine on an Ecto repository. Standalone development uses SQLite. A host application can supply its Postgres repository and Oban instance. Neuron has no Phoenix dependency.

Dgraph stores domain knowledge: organizations, people, relationships, sources, snapshots, posts, requirements, clients, assertions, and campaign leads. SQL stores execution state, stage checkpoints, output snapshots, selection reservations, and transition history. Prompt/model traces use telemetry.

## Setup

Install Elixir 1.20 / compatible Erlang, Git, Chromium, and the native build tools needed by Exqlite and Htmd. Private Pinocchio access requires your GitHub SSH key. Start Dgraph with gRPC available at `localhost:9080` and HTTP administration at `localhost:8080`.

```sh
mix deps.get
mix compile
mix neuron.models.fetch
mix neuron.migrate
mix neuron.dgraph.migrate
```

SQL and Dgraph migrations are versioned. Run SQL migrations before starting the application; run both before research. See [migrations](docs/migrations.md) for deployment and host-repo details.

Configure the live services in your shell or application's runtime configuration:

```sh
export ZAI_API_KEY='...'
export BROWSER_USE_API_KEY='...'
export CHROMIUM=/usr/bin/chromium
mix neuron.models.fetch
# Downloads pinned intfloat/multilingual-e5-small files into priv/models.

```

Embeddings run locally inside the BEAM using Bumblebee, Nx.Serving and EXLA. Install a C++ compiler (Debian/Ubuntu: `sudo apt-get install g++`) before compiling dependencies. Model files stay under ignored `priv/models` and must be downloaded before startup or release packaging. Runtime never calls an embedding endpoint. ZAI generation always uses `glm-5.3-flash`. Search runs platform-tailored queries across DuckDuckGo, Google, Yandex, and native LinkedIn, X, and Reddit search as concurrent browser pages; source browsing prefers local Chromium.

## Interactive use

```sh
mix neuron.repl
```

The Owl console supports:

```text
campaign
campaign https://nyx-labs.org
show RUN_ID
events RUN_ID
cancel RUN_ID
resume RUN_ID
quit
```

Campaign intake asks at most eight fields: organization, field, offer, target roles, target organizations, geography, exclusions, and lead count. A supplied URL is scraped to fill those fields. Multiple inferred campaigns require approval. The console starts runs asynchronously and returns their IDs; use `show` to inspect results.

Campaign and research attempt run IDs are UUIDs. A stable `campaign_id` groups executions; `parent_run_id` links ingestion children to their executing parent. Reuse the normalized campaign brief to suppress previously returned people across its runs.

## Library use

```elixir
{:ok, id} = Neuron.start_run(Neuron.Coordinator.Campaign, %{
  organization: "example.org",
  field: "security",
  offer: "Security research partnership",
  target_roles: ["Founder", "Head of Security"],
  target_organizations: ["Software companies"],
  geography: ["United Kingdom"],
  exclusions: ["branch offices"],
  lead_count: 3
})

Neuron.get_run(id)
# %{id: ..., status: :planning | :executing | :needs_input | :complete | :failed, ...}

case Neuron.await_run(id, 900_000) do
  {:ok, run} -> run.leads
  {:needs_input, run} -> run.result
  {:error, run_or_timeout} -> run_or_timeout
end
```

Completed responses retain `result` and also expose `leads`, `people`, `posts`, `organization`, `campaign`, and `target_profile` at the top level when supplied by the profile. A timeout stops waiting; it does not cancel the durable run.

For research of a particular organization:

```elixir
{:ok, result} = Neuron.Research.run("nyx-labs.org", %{
  preferred_geographies: ["United Kingdom"],
  requirements: [%{category: "industry", description: "security research"}]
}, timeout: 900_000)

result.leads
result.source_urls
```

The standalone research API researches a specified organization. Campaigns instead treat the initial organization as the seller and search for external prospects using approved market, role, and geography criteria.

User assertions take precedence in reconciliation prompts. Source preference is advisory; contact qualification favors official company evidence, corroborated professional profiles, and company email addresses. Ecto embedded schemas validate domain outputs, and the model is asked to repair invalid final research output. Empty verified results remain empty.

## Persistence and observability

Every committed transition increments a version and records an event atomically with the next Oban job. Research checkpoints search, browse, extract, enrich, draft, and persist stages. A retry resumes its stage; completed stages are retained. GenStage bounds concurrent source processing within a stage.

```elixir
Neuron.events(id)
Neuron.cancel_run(id)
Neuron.resume_run(id) # failed runs; failed pipelines keep their checkpoint
```

Attach normal `:telemetry` handlers for Neuron, Ecto, and Oban. Neuron emits every event both at its specific event name and through the root `[:neuron]` event, so a consumer can capture the complete trace. Prompt and model payloads are controlled by `capture_payloads`; production applications should attach their own sink. SQL retains durable transition history through `Neuron.events/1`.

See [operations](docs/operations.md) for event names, retry behavior, and shutdown.

## Validation

```sh
mix format --check-formatted
mix test
NEURON_DGRAPH_ENABLED=true mix test --include integration test/neuron_dgraph_integration_test.exs test/neuron_campaign_pipeline_integration_test.exs
# Or start an isolated Dgraph with Podman:
bash scripts/dgraph_integration.sh
bash scripts/postgres_integration.sh
```

Unit tests use explicit model/browser fixtures and real SQLite/Oban migrations. The Dgraph integration test requires a running database and checks replay-safe writes. Neither test suite claims to validate a live ZAI/Browser Use research session.

## Documentation

- [Architecture and durable FSM semantics](docs/architecture.md)
- [Configuration and embedding in a host application](docs/configuration.md)
- [Public APIs and extension contracts](docs/library.md)
- [Versioned migrations](docs/migrations.md)
- [Operations and telemetry](docs/operations.md)
