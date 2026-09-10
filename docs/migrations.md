# Migrations

Run migrations as a deployment step before starting workers. They are never silently applied at application startup.

## SQL runtime

```sh
mix neuron.migrate
```

The task starts the configured repo with `Ecto.Migrator.with_repo/2`, then runs pending files in `priv/repo/migrations` using Ecto's migration ledger. Migration `20260909000002` adds campaign-scoped SQL selection reservations with a unique campaign/person key. Migration `20260910000001` adds `neuron_usage`, one row per model call and per browser session, which is what `get_run/1` aggregates into `usage`. The initial migration creates Oban's tables through `Oban.Migration`, plus `neuron_machines`, `neuron_events`, and `neuron_graph_migrations`. Re-running the task skips applied versions.

Standalone SQLite defaults to `neuron.db`. Tests use `neuron_test.db`; the `test` Mix alias runs SQL migrations before application startup. Production requires `NEURON_DATABASE` when using the supplied runtime configuration.

For a host Postgres repo, configure `:neuron, :repo` to that module. Run Neuron's migration directory through the host release's Ecto migration runner, or copy the initial migration into the host's versioned migration sequence. If Oban is already migrated by the host, omit the duplicate Oban migration operations in the copied migration. Neuron and its Oban instance must use the same repo and database prefix so state and enqueue operations share a transaction.

Future changes use new timestamped `.exs` files. Never edit an applied migration. Normal Ecto rollback procedures apply; rolling back the initial migration deletes execution history and Oban jobs and must only be done deliberately.

## Dgraph

```sh
mix neuron.dgraph.migrate
mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
```

The task requires SQL migrations first. It applies sorted, immutable `.dql` files in `priv/dgraph/migrations`, recording each filename only after Dlex reports successful schema application. The baseline declares the dedicated 384-dimensional multilingual E5 vector index used by all current graph writes and similarity queries. Version 000005 adds stable external identities and 000006 adds document history, assertions, current knowledge projections, and freshness indexes. Versions 000007 and 000008 add embedding-space isolation and queryable outreach channels. Applied files are skipped.

Dgraph schema application and SQL ledger insertion are separate transactions. A crash between them reapplies the same schema file; files must therefore be idempotent. Run one migration process at a time. Pair each SQL runtime database with its intended Dgraph database: a ledger from another environment cannot establish that a fresh graph is migrated.

Add future Dgraph changes as new numbered files and update `Neuron.Graph.Schema.definition/0`, which provides the complete schema for test setup. Schema removal/data migration needs an explicit reviewed migration; the runner does not delete data or pretend to roll it back.

HTTP administration defaults to port 8080; gRPC client traffic defaults to 9080. Changing transport is explicit. No transport fallback is performed.

## Existing execution data

The SQL runtime is a new persistence format. Old execution-store directories are not imported by these migrations. Keep any historical data you need before deploying, and start new runs after migration. Existing Dgraph data remains in place; only newly written stable identities participate in replay-safe upserts.
