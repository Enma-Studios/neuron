# Migrations

Neuron keeps execution state in Mnesia and domain facts in Dgraph. Their
schemas are migrated independently so an application can provision or repair
one store without changing the other.

## Run migrations

Run migrations from the release or checkout that contains the code being
deployed:

```sh
# Mnesia execution tables (default data directory and backend)
mix neuron.mnesia.migrate

# Dgraph schema (gRPC is the default: localhost:9080)
mix neuron.dgraph.migrate

# Explicit Dgraph transport and endpoint
mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
mix neuron.dgraph.migrate --endpoint localhost:8080 --transport http
```

The Mnesia task accepts `--data-dir PATH` and `--backend mnesia|rocksdb`:

```sh
mix neuron.mnesia.migrate --data-dir /var/lib/neuron --backend rocksdb
```

The Dgraph task accepts `--endpoint HOST:PORT` and `--transport http|grpc`.
Task options override application configuration for that invocation. The
default configuration uses `localhost:9080` with gRPC; HTTP on `localhost:8080`
is an explicit choice.

## Version tracking

Applied versions are stored in the Mnesia `neuron_migration` table as records
containing:

- the backend (`:mnesia` or `:dgraph`)
- the integer version
- the migration name
- the UTC application timestamp

Inspect the ledger from IEx:

```elixir
Neuron.Storage.migration_status()
Neuron.Storage.migration_status(:mnesia)
Neuron.Storage.migration_status(:dgraph)
```

The current versions are registered in `Neuron.Migrations`:

- Mnesia v1, `create_core_tables`
- Dgraph v4, `graph_schema`

Migration entries are append-only. A successful version is recorded only after
its schema operation succeeds. If a task fails, fix the dependency or
configuration and rerun it; the failed version remains unapplied.

The Dgraph task reapplies the current schema when its ledger is already at the
current version. This keeps a new or restored Dgraph instance consistent with
the local ledger while retaining idempotent Dgraph `ALTER` behavior.

## Deployment order

For a new environment:

1. Provision persistent Mnesia storage and Dgraph.
2. Run `mix neuron.mnesia.migrate` with the production data directory.
3. Run `mix neuron.dgraph.migrate` against the Dgraph gRPC listener.
4. Start the release and verify the migration ledger.

For an upgrade, run the tasks from the new release before admitting traffic.
Back up the Mnesia data directory before changing storage configuration. The
tasks do not delete domain facts or execution records, and they do not provide
automatic down migrations.

## Adding a version

Migration versions live in `Neuron.Migrations`. Add the next Mnesia version
when the durable table definitions change, and increment the graph schema
version in `Neuron.Graph.Schema` when Dgraph predicates or indexes change.
Keep the migration name stable once deployed, update the relevant schema
definition, add or update a focused test, and run both migration tasks against
a disposable store before deployment.

Do not reuse a released version number. A corrected migration receives a new
version so every node can apply the same ordered history.
