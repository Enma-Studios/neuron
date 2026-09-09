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
| `NEURON_DGRAPH_ENDPOINT` | Dgraph endpoint | `localhost:8080` |
| `NEURON_DGRAPH_TRANSPORT` | Dgraph transport (`http` or `grpc`) | `http` |
| `NEURON_DGRAPH_ENABLED` | Enable Dgraph | `true` in dev, `false` in tests |
| `NEURON_DATA_DIR` | Production Mnesia directory | `data/neuron` |
| `NEURON_BROWSER_POOL_SIZE` | Pinocchio pool size in releases | `4` |
| `NEURON_RECOVERY_ENABLED` | Re-admit unfinished runs | `true` |
| `NEURON_ENABLE_ROCKSDB` | Fetch the optional Mnesia RocksDB backend | unset |
| `NEURON_ENABLE_LOCAL_ML` | Fetch optional Nx/Bumblebee/EXLA dependencies | unset |
| `NEURON_CAPTURE_PAYLOADS` | Include complete telemetry payloads | `false` |

The default local Dgraph HTTP API is `localhost:8080`. For a gRPC endpoint:

```sh
NEURON_DGRAPH_ENDPOINT=localhost:9080 NEURON_DGRAPH_TRANSPORT=grpc mix run -e 'IO.inspect(Neuron.Dgraph.connection())'
```

The main application keys are `storage`, `dgraph`, `model`, `browser`,
`limits`, `recovery`, `prompts`, `embeddings`, and `telemetry`. Per-call
options can override `run_id`, `trace_id`, `task_id`, `operation_id`,
`attempt`, timeouts, concurrency, `max_sources`, `re_enrich`,
`session_transcript`, `model_provider`, `embedding_provider`, and a test
browser `adapter`.

`NEURON_RECOVERY_ENABLED=false` is for controlled maintenance. It prevents
automatic re-admission but does not delete or alter stored records.

## Optional native dependencies

Set `NEURON_ENABLE_ROCKSDB=true` before `mix deps.get` to use
`mnesia_rocksdb`; the portable fallback is Mnesia `disc_copies`. Set
`NEURON_ENABLE_LOCAL_ML=true` to fetch the optional local embedding stack.
