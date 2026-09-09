# Configuration reference

Neuron uses standard Mix configuration. Shared defaults live in
`config/config.exs`; development, test, and production overlays live in
`config/dev.exs`, `config/test.exs`, and `config/runtime.exs`. Set environment
variables before starting Mix or a release.

## Credentials

```sh
export ZAI_API_KEY="..."
export BROWSER_USE_API_KEY="..."
```

Z.AI is pinned to `glm-5.3-flash`. Browser Use powers DuckDuckGo search and is
the fallback when local Chromium is blocked. Secrets are never persisted in
Mnesia or Dgraph.

## Environment variables

| Variable | Meaning | Default |
| --- | --- | --- |
| `ZAI_API_KEY` | Z.AI authorization | unset |
| `ZAI_BASE_URL` | Z.AI base URL in releases | `https://api.z.ai/api/paas/v4` |
| `BROWSER_USE_API_KEY` | Browser Use authorization | unset |
| `CHROMIUM` | Chromium executable | first existing `/usr/bin/chromium`, `/snap/bin/chromium`, `/usr/bin/chromium-browser` |
| `NEURON_DGRAPH_ENDPOINT` | Dgraph endpoint | `localhost:9080` |
| `NEURON_DGRAPH_TRANSPORT` | Dgraph transport (`http` or `grpc`) | `grpc` |
| `NEURON_DGRAPH_ENABLED` | Enable Dgraph | `true` in dev, `false` in tests |
| `NEURON_DATA_DIR` | Production Mnesia directory | `data/neuron` |
| `NEURON_BROWSER_POOL_SIZE` | Pinocchio pool size in releases | `4` |
| `NEURON_RECOVERY_ENABLED` | Re-admit unfinished runs | `true` |
| `NEURON_ENABLE_LOCAL_ML` | Fetch optional Nx/Bumblebee/EXLA dependencies | unset |
| `NEURON_CAPTURE_PAYLOADS` | Include complete telemetry payloads | `false` |

The default local Dgraph gRPC endpoint is `localhost:9080`:

```sh
NEURON_DGRAPH_ENDPOINT=localhost:9080 NEURON_DGRAPH_TRANSPORT=grpc mix run -e 'IO.inspect(Neuron.Dgraph.connection())'
```

Use the HTTP endpoint explicitly when needed:

```sh
NEURON_DGRAPH_ENDPOINT=localhost:8080 NEURON_DGRAPH_TRANSPORT=http mix run -e 'IO.inspect(Neuron.Dgraph.connection())'
```

Apply the durable schemas with Mix tasks:

```sh
mix neuron.mnesia.migrate
mix neuron.dgraph.migrate
mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
```

Both migrations are safe to repeat. The Mnesia task accepts `--data-dir` and
`--backend mnesia|rocksdb`; the Dgraph task accepts `--endpoint` and
`--transport http|grpc`.

Applied versions are recorded in Mnesia's `neuron_migration` table with the
backend, version, migration name, and timestamp. Migration definitions are
append-only in `Neuron.Migrations`; the current Mnesia version is 1 and the
current Dgraph schema version is 4. The Dgraph task reapplies the current
schema when the ledger is already current, allowing schema reconciliation
after a Dgraph reset.

The main application keys are `storage`, `dgraph`, `model`, `browser`,
`limits`, `recovery`, `prompts`, `embeddings`, and `telemetry`. Per-call
options can override `run_id`, `trace_id`, `task_id`, `operation_id`,
`attempt`, timeouts, concurrency, `max_sources`, `re_enrich`,
`session_transcript`, `model_provider`, `embedding_provider`, and a test
browser `adapter`.

`NEURON_RECOVERY_ENABLED=false` is for controlled maintenance. It prevents
automatic re-admission but does not delete or alter stored records.

## Optional native dependencies

`mnesia_rocksdb` is included in the normal dependency set and is selected by
the default `storage: [backend: :rocksdb]` configuration. It needs a native
compiler/toolchain for the host architecture; startup fails when the adapter
cannot load. Set `NEURON_ENABLE_LOCAL_ML=true` to fetch the optional local
embedding stack.
