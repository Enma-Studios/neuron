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

The default Oban queues are `orchestrators: 4` and `agents: 4`. Pruning retains finished jobs for one day; event history is retained independently. Lifeline rescues orphaned jobs after one hour. Set the rescue duration above your longest legitimate job; campaign jobs may await several research attempts. Queue concurrency controls job execution, and source concurrency controls work inside a stage.

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
  queues: [orchestrators: 4, agents: 4],
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
| `BROWSER_USE_API_KEY` | Required for all browsing; Browser Use is the only browser provider |
| `BROWSER_USE_PROFILE_ID` | Optional, default unset; see the warning below before setting it |
| `NEURON_FLEET_SESSIONS` | `1` in production; browser sessions opened per search fleet |
| `NEURON_FLEET_PAGES` | `4` in production; concurrent pages multiplexed per fleet session |
| `NEURON_CAPTURE_PAYLOADS` | `false`; production telemetry payload setting |

Generation uses only `glm-5.3-flash`; passing another model name does not select a different model. The embedding model is independent of text generation and runs locally in the BEAM. There is no remote embedding provider.

All browsing runs on Browser Use cloud browsers; there is no local browser provider. Neuron traces each attempt. Missing infrastructure is never replaced with fabricated output.

## Search engines and the browser fleet

Searches run on every enabled engine through `:neuron, :search, :engines` (DuckDuckGo, Google, Yandex, LinkedIn, X, and Reddit by default). The model tailors each query to its platform before anything runs: LinkedIn, X, and Reddit get native, operator-free queries, while the keyword engines keep operators such as `site:` and quoted phrases, aimed at pages a prospective buyer publishes itself.

`BROWSER_USE_PROFILE_ID` is a supported optional setting and is unset by default. Setting it sends a logged-in Browser Use profile to every new cloud session, which is what native LinkedIn and X search needs. **It is a logged-in path and it carries account and terms-of-service risk to whoever owns that profile.** It exists for standalone operation by the profile's own owner. An embedding host does not set it: the Neureni host runs the public engines only, with no profile, and resolves people and contacts through its own provider waterfall.

A page that renders a login gate, a consent wall or a bot check is never worked around. It is recorded as a skipped engine with its reason and the remaining engines carry the round. `Neuron.Search.wall_reason/1` makes that decision, reading the final URL and, when the page was small enough to be a wall rather than a results page, the engine's own `blocked?/1` and `gated?/1` markers. It returns `{kind, reason}` where kind is `:login_gate`, `:consent_wall` or `:bot_check`, and that kind travels onto the round's failure entries. Without a profile, LinkedIn and X report a login gate and are skipped on every query.

Result links in a rendered results page are the engine's own tracking redirects, so transcript links are unwrapped through `Neuron.Search.Engine.unwrap/1` before the model reads them. Harvesting a wrapper would ingest the search engine rather than the prospect.

Interaction-heavy pages (LinkedIn, X, Reddit, and other rendered feeds, configurable through `:neuron, :browser, :rich_hosts`) are never snapshotted whole: a bundled Turndown build is injected in the browser, and only the cleaned main section travels back as Markdown — both for search transcripts and for ingested source documents.

Campaign searches run as one fleet wave: `sessions` Browser Use cloud sessions each multiplex `pages_per_session` concurrent tabs, so concurrency scales with pages rather than browser count — 1 x 4 = 4 concurrent pages by default. One sub-agent controls each page and returns a transcript (final URL, title, text, links); the model then harvests prospect URLs from the transcripts, and every harvested URL must literally appear in its transcript. `:neuron, :browser, :fleet` accepts `sessions`, `pages_per_session`, and `timeout`.

## Per-run options

Common options are `id:`, `trace_id:`, and `timeout:`. The timeout for `await_run` only bounds waiting. Research additionally accepts `queries:`, `max_sources:` (8), `search_concurrency:` (2), `browser_concurrency:` (3), `re_enrich:` (true), `assertions:`, and `persist:` (true). Campaign discovery accepts the bounded search-budget options documented below.

`persist: false` is an explicit no-graph-write operation; it does not claim successful ingestion. Fixtures may supply browser `adapter:` and `model_provider:` modules. Durable inputs and options may contain module atoms but cannot contain functions, processes, ports, or references. Avoid placing API keys in durable per-run options; configure secrets at application level.

## Local embeddings

Run `mix neuron.models.fetch` to download pinned `intfloat/multilingual-e5-small` files into `priv/models/multilingual-e5-small`. The task and the loader both resolve that directory through `Neuron.Embedding.directory/0`, which is Neuron's own application directory rather than the working directory, so a host application's fetch lands where its startup reads. Startup distinguishes a model that was never fetched from one sitting in the wrong `priv` and from one whose manifest does not match configuration. The model uses 384 dimensions, mean pooling, and L2 normalization. Query inputs receive `query: `; documents receive `passage: `. See the [model card](https://huggingface.co/intfloat/multilingual-e5-small).

Configure `:neuron, :embeddings` through application config: `model`, `revision`, `directory` (relative to priv), `dimensions`, `batch_size` (4), and `sequence_length` (512). Run the download task before building a release. Startup checks the local manifest and fails if it is missing or does not match configuration. EXLA requires a C++ compiler. Model weights are not committed to Git.

Do not mix embedding models or dimensions in an existing graph index: re-ingest/reindex the corpus before switching the query model.

## Campaign budgets and ranking

Campaign run options: `max_rounds: 12`, `max_queries: 50`, `searches_per_round: 8`, `max_pages: 96`, `batch_size: 8`, `budget_seconds: 7200`, and `harvest_concurrency: 4`. The time budget stops new scheduling; in-flight batches finish. The requested lead count is a target, not a truncation limit.

Selection options: `selection_threshold: 0.5` and `weights` (market 0.35, role 0.20, geography 0.15, evidence 0.15, freshness 0.15). Market relevance combines lexical fit and embedding similarity equally. Freshness decays with a 90-day half-life. Contact evidence and explicit exclusions are hard eligibility checks, independent of score.

Contact preference is separate from fit scoring: eligible company-email leads rank before social-only leads. `:neuron, :selection` accepts `channel_order` (default `["email", "linkedin", "x", "social"]`). Email remains the primary channel. Every returned lead has its preferred-channel draft and all verified channel options.
