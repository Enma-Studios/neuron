# Neuron

Neuron is the durable OTP core for Neureni's agentic intelligence workflows. It
runs coordinators and delegated agents as `gen_statem` processes, stores
execution state in Mnesia, searches the web through Browser Use and
DuckDuckGo, cleans source pages into Markdown, embeds the resulting evidence,
and publishes domain facts to Dgraph through a retryable outbox.

Source repository: <https://github.com/Enma-Studios/neuron>

The project is designed to sit behind a Phoenix controller plane later. The
OTP application is usable on its own today, so jobs can run concurrently in a
worker-only deployment or behind an HTTP/API layer.

Deeper reference material is available in [the architecture guide](docs/architecture.md)
and [the operations runbook](docs/operations.md). See the [library guide](docs/library.md)
for the complete module and contract reference and the [configuration guide](docs/configuration.md)
for all runtime keys.

## What runs in a Neuron job

A normal intelligence job follows this path:

1. A coordinator receives a goal, search query, URLs, and a campaign fit
   profile.
2. `Neuron.Search.DuckDuckGo` opens DuckDuckGo through Browser Use and returns
   ranked links, snippets, and decoded destination URLs.
3. Each URL is fetched in parallel. Local Chromium through Pinocchio is tried
   first; a recorded local failure causes a Browser Use session to be created.
4. `Neuron.Snapshot` removes executable/boilerplate markup and converts the
   remaining page to Markdown with Htmd.
5. The configured embedding provider creates a vector for the snapshot.
6. `Neuron.Lead` compares the candidate evidence with requirements and
   preferred geographies, returning a score, selection flag, matched evidence,
   and human-readable reasons.
7. A durable outbox entry records the snapshot, embedding, and decision. The
   outbox retries publication to Dgraph while the run remains complete locally.
8. Every state change, fetch, model call, embedding, database transaction,
   decision, and publication emits correlated telemetry.

The default coordinator is an echo profile for smoke tests. The intelligence
coordinator is the end-to-end profile described below.

## Requirements

- Elixir 1.20 and OTP 29 (the versions used by the project)
- Git with an SSH key that can read `Enma-Studios/pinocchio`
- A Chromium executable for local browsing (`chromium`, `chromium-browser`,
  or another binary selected with `CHROMIUM`)
- Dgraph v25.x for domain persistence and graph search
- Podman and `curl` for the integration harness
- A Z.AI API key if model completion or Z.AI-specific endpoints are used
- A Browser Use API key for Browser Use sessions and DuckDuckGo search

The default development/test path can run without Dgraph or Chromium: Dgraph
writes remain pending in the outbox and the browser adapter records a local
blockage. Live search and live page fetching require the corresponding API
key.

## Clone and install

Use the canonical repository URL. SSH is required because Pinocchio is a
private dependency:

```sh
git clone git@github.com:Enma-Studios/neuron.git
cd neuron
ssh -T git@github.com
mix deps.get
mix compile
```

If the SSH agent has multiple keys, select the GitHub key with your normal
`~/.ssh/config` host entry. Do not put private keys or API keys in the
repository.

The optional native dependencies are intentionally opt-in:

```sh
# mnesia_rocksdb for the durable RocksDB-backed execution store
NEURON_ENABLE_ROCKSDB=true mix deps.get

# Nx/Bumblebee/EXLA for local model embeddings
NEURON_ENABLE_LOCAL_ML=true mix deps.get
```

`mnesia_rocksdb` and the local ML stack need a compiler/toolchain appropriate
to the host architecture. Without those flags, Neuron uses Mnesia
`disc_copies` and its deterministic embedding fallback.

## Credentials and environment

Set secrets in the shell, a secret manager, or your process supervisor:

```sh
export ZAI_API_KEY="..."
export BROWSER_USE_API_KEY="..."
```

The supported Z.AI model is fixed to `glm-5.3-flash`; there is no alternate
model setting.

Useful runtime variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `CHROMIUM` | Chromium executable path | first existing path among `/usr/bin/chromium`, `/snap/bin/chromium`, `/usr/bin/chromium-browser` |
| `NEURON_DATA_DIR` | Production Mnesia directory | `data/neuron` |
| `ZAI_API_KEY` | Z.AI authorization | unset |
| `BROWSER_USE_API_KEY` | Browser Use authorization | unset |
| `NEURON_CAPTURE_PAYLOADS` | Include full payloads in telemetry | `false` |
| `NEURON_BROWSER_POOL_SIZE` | Pinocchio browser pool size | `4` |

Development configuration lives in `config/config.exs` and `config/dev.exs`.
Production secrets and paths are read in `config/runtime.exs`. Test
configuration disables external Dgraph connections and uses a mock Pinocchio
session.

## Start the OTP application

Neuron starts as a normal OTP application:

```sh
iex -S mix
```

The supervision tree starts, in order, durable storage, the Dgraph boundary,
the outbox publisher, registries, dynamic run/agent supervisors, and recovery.
When active runs are found in Mnesia, `Neuron.Recovery` re-admits them to the
run supervisor.

For a production release, provide `ZAI_API_KEY`, `BROWSER_USE_API_KEY`,
`CHROMIUM`, and `NEURON_DATA_DIR` through the release environment, then run
`mix release` using the normal Elixir release workflow.

## Public API

### Campaign intake and lead targets

Campaigns are the operating surface for go-to-market work. The intake contract
has eight questions at most: organization, field, offer, target roles, target
organizations, geography, exclusions, and the requested unique lead count.
`Neuron.Campaign.questions/0` returns the questions for a controller or chat
surface, while `Neuron.Campaign.question_prompt/1` returns only the unanswered
ones.

If a website URL is supplied, Neuron first fetches it with the normal local
Chromium-first browser policy, converts the page to Markdown, and asks the
configured Z.AI `glm-5.3-flash` provider to extract answers. Unknown answers are
returned as prompts; they are never invented. The caller can resume intake by
passing the answers back to `Neuron.Campaign.intake/2`:

```elixir
{:needs_input, %{questions: questions, partial: partial}} =
  Neuron.Campaign.intake(%{url: "https://example.com"})

{:ok, campaign} =
  Neuron.Campaign.intake(%{
    answers: %{
      organization: "example.com",
      field: "B2B cybersecurity",
      offer: "Security assessment partnerships",
      target_roles: ["CTO", "VP Engineering"],
      geography: ["US", "Canada"],
      lead_count: 3
    }
  })
```

The target counter is owned by `Neuron.Campaign`, outside the research model.
`Neuron.Campaign.run/2` starts independent research attempts, deduplicates by
company email, profile URL, or person name, and stops when `lead_count` unique
leads are collected. `max_attempts` bounds retries; failure returns the
partial leads and per-attempt errors. To run it under `gen_statem`, use
`Neuron.Coordinator.Campaign`:

```elixir
{:ok, run_id} =
  Neuron.start_run(Neuron.Coordinator.Campaign, campaign,
    id: "campaign-nyx",
    max_attempts: 4,
    session_transcript: "/tmp/campaign-nyx-transcript"
  )
```

When the URL or supplied answers leave required fields unknown, the coordinator
enters `:needs_input` and returns the bounded question list. Supply the answers
without starting a second process:

```elixir
Neuron.get_run("campaign-nyx")
Neuron.provide_run("campaign-nyx", %{field: "cybersecurity", lead_count: 3})
```

The completed result includes `campaign_run_id`, `target_count`, `leads`, and
the attempt failures. Each attempt has its own run and outbox identity while
remaining correlated to the parent campaign run in telemetry.

### Start and inspect a run

```elixir
{:ok, run_id} =
  Neuron.start_run(Neuron.Coordinator.Default, %{goal: "discover fintech prospects"})

Neuron.get_run(run_id)
Neuron.list_runs()
Neuron.events(run_id)
Neuron.cancel_run(run_id)
Neuron.resume_run(run_id)
```

For callers that need the lead payload in the function return, use the
blocking API. It returns the terminal run envelope and exposes campaign result
fields such as `leads` at the top level as well as under `result`:

```elixir
{:ok, response} = Neuron.run(Neuron.Coordinator.Campaign, campaign, timeout: 300_000)
response.leads
response.result.leads
```

`Neuron.await_run/2` provides the same envelope when a run was started with
`Neuron.start_run/3`. `Neuron.get_run/1` remains the non-blocking inspection
API and returns the same exposed fields for completed runs.

A run moves through `:queued`, `:planning`, `:executing`, and either
`:complete`, `:failed`, or `:cancelled`. Run and operation state is persisted
before and after side effects.

### Delegate parallel work

```elixir
{:ok, agent_id} =
  Neuron.spawn_agent(run_id, :enrich, Neuron.Agent.Echo, %{company: "Acme"})

Neuron.get_agent(agent_id)
Neuron.cancel_agent(agent_id)
```

Custom coordinators implement `Neuron.Coordinator`:

```elixir
defmodule MyCoordinator do
  @behaviour Neuron.Coordinator

  @impl true
  def plan(input, _context), do: {:ok, input}

  @impl true
  def run(plan, context) do
    # context[:run_id], context[:options], and context[:plan] are available.
    {:ok, %{plan: plan, run_id: context.run_id}}
  end
end
```

Custom delegated workers implement `Neuron.Agent.Worker`:

```elixir
defmodule MyWorker do
  @behaviour Neuron.Agent.Worker

  @impl true
  def run(input, context) do
    {:ok, %{input: input, run_id: context.run_id, agent_id: context.agent_id}}
  end
end
```

### Run web intelligence and fit scoring

A fit profile can express requirements, preferred geographies, and a selection
threshold:

```elixir
fit_profile = %{
  requirements: [
    %{category: "industry", description: "fintech payments"},
    %{category: "buyer", description: "B2B platform"}
  ],
  preferred_geographies: ["US", "Canada"],
  threshold: 0.7
}

Neuron.start_run(Neuron.Coordinator.Intelligence, %{
  urls: ["https://example.com"],
  fit_profile: fit_profile
})
```

For query-first discovery, search DuckDuckGo and then explore the returned
links:

```elixir
Neuron.Intelligence.discover("B2B fintech payment platforms", fit_profile,
  run_id: "campaign-2026-09-09",
  max_concurrency: 4
)
```

The return value is a list of per-URL results. Each successful result contains
`provider`, `snapshot`, `embedding`, `decision`, and `outbox_id`.

The lower-level APIs are also available:

```elixir
Neuron.Search.web("Elixir OTP")
Neuron.Search.DuckDuckGo.search("B2B fintech")
Neuron.Intelligence.explore("https://example.com", fit_profile)
```

### Understand a lead decision

```elixir
{:ok, decision} =
  Neuron.Lead.evaluate(
    %{name: "Acme", body: "Fintech payments for US teams", geography: "US"},
    fit_profile
  )

%{
  score: 1.0,
  selected: true,
  reasons: [
    "Matched industry: fintech payments",
    "Matched buyer: B2B platform",
    "Geography US is preferred",
    "Selected with score 1.0 at or above threshold 0.7"
  ],
  evidence: [...]
} = decision
```

The current scorer gives requirements 80% of the score and geography 20%.
Requirement matching records which criterion matched and includes the source
excerpt. The final reason always states why the candidate was selected or
rejected. This explanation is returned to callers, emitted in telemetry, and
stored as a run event when a `run_id` is supplied.

## Browser and search providers

### Local Chromium first

Neuron configures Pinocchio with headless Chromium and a bounded session pool.
The local provider uses `Pinocchio.Browser.start_session/0`, navigates with
`visit_and_wait/3`, and reads the current URL, title, and document HTML.

```elixir
Neuron.Browser.fetch("https://example.com", run_id: "run-1", task_id: "page:fetch")
```

The `:local` provider is attempted first by default. A start, navigation, or
read error emits `[:neuron, :browser, :blocked]`; Neuron then tries Browser
Use. You can force a provider:

```elixir
Neuron.Browser.fetch("https://example.com", provider: :local)
Neuron.Browser.fetch("https://example.com", provider: :browser_use)
```

For tests or adapters, pass `adapter: MyBrowserAdapter` to inject a module
implementing `fetch/2`.

### Browser Use fallback

Browser Use is provisioned through Pinocchio's v4 provider. Neuron creates a
provider-owned browser, connects to its returned CDP endpoint, navigates with
the same Pinocchio API, reads the page, and stops the remote browser in an
`after` block. The API key is never persisted in Mnesia or Dgraph.

### DuckDuckGo search

`Neuron.Search.DuckDuckGo` builds an HTML search URL, forces
`provider: :browser_use`, parses result anchors/snippets, decodes DuckDuckGo
redirect URLs, removes duplicates, and emits a search trace. Use
`Neuron.Intelligence.discover/3` when the search should feed the exploration
pipeline automatically.

## Snapshots and embeddings

`Neuron.Snapshot.from_html/2` removes script, style, noscript, iframe, and
comment blocks, normalizes whitespace, and converts the cleaned HTML with
Htmd. It returns:

```elixir
%{
  markdown: "...",
  content_hash: "sha256...",
  extraction_version: 1,
  url: "...",
  title: "..."
}
```

If Htmd is unavailable or its NIF fails, a conservative tag-stripping
fallback keeps ingestion usable.

`Neuron.Embedding.provider/0` selects the configured provider. The default
local provider is deterministic and dimension-compatible while native ML
weights are not provisioned. Enable `NEURON_ENABLE_LOCAL_ML=true` before
fetching dependencies when a Bumblebee/Nx implementation is ready for the
host.

## Dgraph graph model

Dgraph stores domain facts; execution state stays in Mnesia. Apply the
versioned schema with a live Dlex connection:

```elixir
{:ok, connection} = Dlex.start_link(hostname: "localhost", port: 8080, transport: :http)
Neuron.Graph.Schema.apply(connection)
```

The schema models:

- `Organization` with people, social accounts, posts, clients, requirements,
  leniencies, sources, assertions, and geographies.
- `Person` with employer, location, social accounts, posts, skills,
  requirements, leniencies, and evidence.
- `SocialAccount` with platform, handle, followers, verification, owner, and
  posts.
- `Post` with author, organization, social account, topics, geography, source,
  body, timestamp, and embedding.
- `Geography` with hierarchy and attached organizations, people, and posts.
- `Requirement`, `Leniency`, and `Capability` nodes with evidence and
  embeddings.
- `ClientProfile` connecting an organization to its client and profile facts.
- `Campaign` and `FitProfile` nodes connecting campaign objectives to target
  entities, requirements, capabilities, exclusions, and geographies.
- `Source`, `Snapshot`, `Evidence`, and `Assertion` provenance nodes.

Full-text, term, trigram, exact, float, and cosine HNSW indexes are defined in
`Neuron.Graph.Schema`. Use the search facade for DQL queries:

```elixir
Neuron.GraphSearch.lexical("payments")
Neuron.GraphSearch.semantic(vector)
Neuron.GraphSearch.hybrid("payments", vector)
Neuron.GraphSearch.profiles("fintech")
Neuron.GraphSearch.fit_profiles("US payment platforms")
```

For repeatable deployments, use the built-in migration tasks. Mnesia
migration is local and preserves existing run records; Dgraph schema
application is idempotent and uses the configured endpoint:

```sh
mix neuron.mnesia.migrate
mix neuron.dgraph.migrate

# Dgraph's gRPC listener, when HTTP and gRPC are exposed separately
mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
```

The default Dgraph connection remains HTTP at `localhost:8080`. Set
`NEURON_DGRAPH_ENDPOINT` and `NEURON_DGRAPH_TRANSPORT` for a release, or pass
the endpoint and transport to the Dgraph migration task.

`GraphSearch.hybrid/3` currently returns the lexical and semantic result sets
with the declared fusion strategy; ranking fusion can be replaced without
changing callers.

### Outbox behavior

```elixir
{:ok, outbox_id} = Neuron.Outbox.enqueue(run_id, :web_snapshot, payload)
Neuron.Storage.pending_outbox()
```

The outbox entry is deterministic for the same `{run_id, kind, payload}`.
Publication to Dgraph is retried on the configured interval. If Dgraph is
unavailable, the local run remains inspectable and the entry remains pending.

## Mnesia durability and recovery

Mnesia tables contain runs, agents, operations, events, and outbox entries.
The configured default requests RocksDB copies when `mnesia_rocksdb` is loaded;
otherwise Neuron explicitly falls back to `disc_copies`.

- Development data: `priv/neuron_data/dev`
- Test data: `tmp/neuron_data/test`
- Production data: `NEURON_DATA_DIR` (default `data/neuron`)

Recovery re-admits unfinished runs after the store is available. A resumed
run re-enters its state machine and repeats the unfinished coordinator work;
checkpoint-level replay of individual model/browser calls is a later
extension. Keep the production data directory on persistent storage.

## Telemetry and traceability

All events use the `[:neuron, ...]` namespace. Metadata may include:

- `trace_id` for the operation chain
- `run_id` and `agent_id`
- `task_id` for the unit of work
- `operation_id` for a database/model/browser operation
- `attempt` for retries

Representative events include:

```text
[:neuron, :run, :state]
[:neuron, :agent, :task]
[:neuron, :model, :request]
[:neuron, :model, :decision]
[:neuron, :browser, :attempt]
[:neuron, :browser, :blocked]
[:neuron, :search, :duckduckgo]
[:neuron, :snapshot, :clean]
[:neuron, :embedding, :embed]
[:neuron, :db, :transaction]
[:neuron, :graph, :upsert]
[:neuron, :outbox, :publish]
[:neuron, :lead, :decision]
```

Payloads are summarized with SHA-256 and byte counts by default. To inspect
full payloads in a controlled environment:

```elixir
config :neuron, telemetry: [capture_payloads: true]
```

Neuron records model-visible reasoning fields and tool calls when Z.AI returns
them. It does not claim to capture hidden chain-of-thought.

Attach handlers with standard Telemetry APIs:

```elixir
:telemetry.attach(
  "neuron-console",
  [:neuron, :lead, :decision],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

## Tests and integration checks

Run formatting and deterministic tests:

```sh
mix format --check-formatted
mix test
```

The default suite excludes the `:integration` tag and does not require a
running Dgraph instance. It covers state machines, durable events, outbox
records, prompts, snapshots, lead explanations, and DuckDuckGo parsing.

Run the Dgraph integration test with Podman:

```sh
scripts/dgraph_integration.sh
```

The script starts `docker.io/dgraph/standalone:v25.4.0`, waits for
`/health`, enables Dgraph for the test environment, applies the schema,
performs a mutation, queries it back, and removes the container on exit.
Customize the container/image/ports with:

```sh
NEURON_DGRAPH_IMAGE=... \
NEURON_DGRAPH_HTTP_PORT=18080 \
NEURON_DGRAPH_GRPC_PORT=19080 \
scripts/dgraph_integration.sh
```

Run live provider checks explicitly:

```sh
# Local Chromium (requires Chromium and no forced provider fallback)
mix run -e 'IO.inspect(Neuron.Browser.fetch("https://example.com", provider: :local))'

# Browser Use-backed DuckDuckGo search
mix run -e 'IO.inspect(Neuron.Search.DuckDuckGo.search("Elixir OTP"))'

# Z.AI web search endpoint (glm-5.3-flash remains the only model)
mix run -e 'IO.inspect(Neuron.Model.ZAI.web_search("Elixir OTP"))'
```

## Troubleshooting

**`Permission denied` or GitHub username prompts during `mix deps.get`**

Pinocchio uses `git@github.com:Enma-Studios/pinocchio.git`. Confirm the SSH
agent has the GitHub key and that `ssh -T git@github.com` succeeds.

**Local browser reports `pinocchio_not_configured`**

Check `CHROMIUM` and the auto-detected paths. Neuron records this as a local
blockage and tries Browser Use when its key is configured.

**Dgraph is unavailable**

Start the Podman harness or a Dgraph instance on the configured gRPC endpoint.
Outbox entries remain pending until publication succeeds.

**Z.AI returns 401 or 429**

Verify `ZAI_API_KEY`, account access, and the active Z.AI resource package.
The request body always uses `glm-5.3-flash`; changing a model environment
variable has no effect.

**RocksDB or EXLA fails to compile**

Unset the corresponding `NEURON_ENABLE_*` flag for the portable fallback, or
install the compiler, Rust/NIF, and architecture-specific libraries required
by that native dependency.

## Project layout

```text
config/                 environment and runtime configuration
lib/neuron.ex           public run/agent API
lib/neuron/run.ex       coordinator gen_statem
lib/neuron/agent.ex     delegated worker gen_statem
lib/neuron/intelligence.ex end-to-end exploration coordinator
lib/neuron/search.ex    DuckDuckGo Browser Use search
lib/neuron/lead.ex      transparent fit scoring
lib/neuron/browser.ex   local Chromium and Browser Use adapters
lib/neuron/snapshot.ex  HTML cleanup and Markdown conversion
lib/neuron/embedding.ex embedding provider contract
lib/neuron/graph*.ex    Dgraph boundary, schema, and search
lib/neuron/storage.ex   Mnesia durability
lib/neuron/recovery.ex  unfinished-run recovery
lib/neuron/telemetry.ex correlated redacted telemetry
scripts/                Podman integration harnesses
test/                   deterministic and tagged integration tests
```

## Development workflow

Use trunk-based development on `main`. Keep commits small and atomic, run
formatting and relevant tests before each commit, and keep the main history
linear. Changes should preserve the provider contracts so a Phoenix controller
plane can call the public APIs without moving execution state out of OTP.
