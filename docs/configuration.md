# Configuration

Configure Neuron through Elixir `config` and your host's `runtime.exs`. Values are explicit; unavailable dependencies or services are failures. `:dgraph, enabled: false` is a deliberate mode for database-independent tests and applications that do not use graph operations.

## Runtime ownership

| Key under `:neuron` | Standalone default | Purpose |
| --- | --- | --- |
| `:repo` | `Neuron.Repo` | Repository for FSM, history, and Oban |
| `:oban_name` | `Neuron.Oban` | Registered Oban instance |
| `:start_repo` | `true` | Start configured repo under Neuron |
| `:start_oban` | `true` | Start configured Oban under Neuron |
| `:oban` | Lite engine, PG notifier | Standalone engine and queue configuration |
| `:prompts` | `[]` | Optional `path:` override; otherwise packaged `priv/prompts` |
| `:telemetry` | `[capture_payloads: false]` | Emit payload hashes/sizes rather than payload bodies |

`Neuron.Repo` uses SQLite, pool size 5, WAL mode, and a 15-second busy timeout. `NEURON_DATABASE` selects the path (default `neuron.db` outside production). The directory must exist and be writable. SQLite and its associated WAL files belong to the same persistent volume.

The default Oban queues are `orchestrators: 4` and `agents: 8`. Pruning retains finished jobs for one day; event history is retained independently. Lifeline rescues orphaned jobs after one hour. Set the rescue duration above your longest legitimate job; campaign jobs may await several research attempts. Queue concurrency controls job execution, and source concurrency controls work inside a stage.

## Host Postgres configuration

Define a normal Ecto repo using `Ecto.Adapters.Postgres` in the host. Configure that repo's credentials there. After applying migrations, a host which starts both repo and Oban itself can configure:

```elixir
config :neuron,
  repo: MyApp.Repo,
  oban_name: MyApp.Oban,
  start_repo: false,
  start_oban: false

config :my_app, Oban,
  name: MyApp.Oban,
  repo: MyApp.Repo,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [orchestrators: 4, agents: 8],
  lifeline: [rescue_after: {1, :hour}],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]
```

Start `MyApp.Repo` before `{Oban, Application.fetch_env!(:my_app, Oban)}` in the host's supervisor and before serving Neuron calls. All Neuron transactions must use the same repository as that Oban instance. Use the default database prefix for Neuron's tables and Oban; alternate prefixes are not currently exposed by Neuron. There is no Phoenix dependency or controller integration to install.

Alternatively, set `start_repo: true` and `start_oban: true` and put the Postgres Oban options under `config :neuron, :oban`. Only one application should own each process.

## Services

| Variable | Default / requirement |
| --- | --- |
| `NEURON_DGRAPH_ENDPOINT` | `localhost:9080` |
| `NEURON_DGRAPH_TRANSPORT` | `grpc`; `http` is explicit |
| `NEURON_DGRAPH_ENABLED` | `true` outside tests |
| `ZAI_API_KEY` | Required for live model calls |
| `ZAI_BASE_URL` | Production override for `https://api.z.ai/api/paas/v4` |
| `BROWSER_USE_API_KEY` | Required for Browser Use search/browsing |
| `BROWSER_USE_PROFILE_ID` | Optional; Browser Use profile sent to new sessions when set |
| `CHROMIUM` | Chromium executable path; common system paths are detected |
| `NEURON_BROWSER_POOL_SIZE` | `4` in production |
| `NEURON_EMBEDDING_ENDPOINT` | Required when using the supplied HTTP embedding provider |
| `NEURON_EMBEDDING_MODEL` | Required alongside the endpoint |
| `NEURON_EMBEDDING_DIMENSIONS` | `384`; must match returned vectors |
| `NEURON_EMBEDDING_API_KEY` | Optional endpoint authentication |
| `NEURON_CAPTURE_PAYLOADS` | `false`; production telemetry payload setting |

Generation uses only `glm-5.3-flash`; passing another model name does not select a different model. The embedding model is independent of text generation. An embedding endpoint accepts `{"model": "...", "input": "..."}` and returns `{"data": [{"embedding": [0.1, ...]}]}`. There is no synthetic vector provider in normal configuration.

Local browsing uses Pinocchio's configured executable/session pool. Browser Use is the explicit alternate browser provider. DuckDuckGo requests start with Browser Use and can try local browsing after a reported failure. Neuron traces each provider attempt. Missing infrastructure is never replaced with fabricated output.

## Per-run options

Common options are `id:`, `trace_id:`, and `timeout:`. The timeout for `await_run` only bounds waiting. Research additionally accepts `queries:`, `max_sources:` (8), `search_concurrency:` (2), `browser_concurrency:` (3), `re_enrich:` (true), `assertions:`, and `persist:` (true). Campaign collection accepts `max_attempts:` (3).

`persist: false` is an explicit no-graph-write operation; it does not claim successful ingestion. Fixtures may supply browser `adapter:` and `model_provider:` modules. Durable inputs and options may contain module atoms but cannot contain functions, processes, ports, or references. Avoid placing API keys in durable per-run options; configure secrets at application level.
