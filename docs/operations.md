# Operations

## Start and stop

Apply SQL and Dgraph migrations, then start with `iex -S mix`, `mix neuron.repl`, or your OTP release. Hosts start their own repo/Oban when ownership flags are disabled. Do not start a second named repo or Oban instance.

Use normal OTP shutdown for the release or `Application.stop(:neuron)` for a manually started application. Committed jobs and checkpoints remain in SQL. Temporary GenStage work is replayed by its Oban stage after a crash. Stopping the console/application does not delete pending jobs; they can execute on the next startup. Cancel a run explicitly if you intend to discard its work.

## Retries, cancellation, and recovery

Each built-in worker permits five attempts. Transient returned errors are Oban failures, and exceptions are re-raised. On the final ordinary error/exception the machine is marked failed. `Neuron.resume_run(id)` preserves a failed pipeline's stage index and checkpoint. A normal coordinator replans on retry.

Lifeline rescues orphaned executing jobs after the configured interval. Because it uses elapsed time, configure `rescue_after` above valid job duration. A killed final attempt may become a discarded Oban job without running Neuron's error handler. `get_run/1`, `resume_run/1`, and `reconcile_run/1` detect a discarded or externally cancelled current-version worker and atomically mark its run failed. Keep Oban's job retention longer than the interval at which you inspect/reconcile such runs.

Cancellation advances the machine version. Pending jobs become stale; an in-flight browser or HTTP call may finish but cannot commit a new state. Cancelling a campaign also cancels its known ingestion children; independently delegated agents still require their own cancellation. A waiting API timeout also leaves the durable run active.

Dgraph stage writes resolve deterministic external IDs in one upsert. Replaying a write should update those nodes, not allocate a new copy. Old facts absent from a new extraction are not automatically deleted. SQL event/checkpoint transactions and remote Dgraph/HTTP calls cannot be one distributed transaction.

## Telemetry

Attach ordinary consumers with `:telemetry.attach_many/4`. Neuron installs no custom file logger. Neuron's span events preserve the existing prefix convention:

```elixir
:telemetry.attach_many(
  "my-neuron-consumer",
  [
    [:neuron, :fsm, :transition],
    [:neuron, :start, :pipeline, :stage],
    [:neuron, :stop, :pipeline, :stage],
    [:neuron, :exception, :pipeline, :stage],
    [:neuron, :browser, :attempt],
    [:neuron, :browser, :blocked],
    [:neuron, :research, :source_failed],
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:neuron, :repo, :query]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

The default Ecto repo emits `[:neuron, :repo, :query]`; a host repo uses its own telemetry prefix. Oban reports job timing, attempts, exceptions, and its own queue/service events. Neuron reports transition versions, run/task IDs, stage names, browser attempts/failures, search results, prompt rendering, model decisions, embeddings, snapshots, and graph queries/writes. Span durations use Erlang native time units. Stop events mark completion of the function, including a returned error; exceptions have their own event.

Run options contain a stable trace ID; run and task IDs correlate source/model activity. By default large telemetry payloads are summarized as hashes and byte sizes. `capture_payloads: true` is explicit. Business selection reasons belong in lead results; telemetry is not a promise to expose a model's private internal reasoning.

## History and export

Rendered prompts, model request/response summaries, and transition events are emitted through the root `[:neuron]` telemetry event with correlation IDs. This telemetry is independent of Oban's finished-job pruning. `Neuron.events(id)` returns durable transition history; telemetry consumers receive prompt and model payloads according to the `capture_payloads` setting.

Campaign runs and their research attempts each use an independently generated UUID. Attempt telemetry carries both `run_id` (the campaign UUID) and `attempt_run_id` (the research UUID), while research receives `parent_run_id` for correlation. Attach a telemetry consumer to `[:neuron]` when you need a complete external run log. SQL checkpoints preserve in-progress outputs when graph persistence fails. Supply credentials through application configuration, not run options stored in SQL. Apply your organization's retention/access controls to the SQL database and exports.

## Checks

`mix test` uses real SQLite and Oban with manual queue draining and explicit external-service fixtures. It tests FSM transitions, stale jobs, cancellation, output retention, stage checkpoints, rollback, failed-stage resumption, GenStage cleanup, schema validation, and domain rules. Tests migrate first through the Mix alias.

`NEURON_DGRAPH_ENABLED=true mix test --include integration test/neuron_dgraph_integration_test.exs test/neuron_campaign_pipeline_integration_test.exs` requires the configured gRPC service and verifies repeat writes, queries, and campaign delivery. `scripts/dgraph_integration.sh` starts a temporary Podman instance on ports 18080/19080 by default:

```sh
NEURON_DGRAPH_HTTP_PORT=18080 NEURON_DGRAPH_GRPC_PORT=19080 bash scripts/dgraph_integration.sh
```

The same runtime suite can use a separately configured Postgres repo:

```sh
bash scripts/postgres_integration.sh
# Or use an existing disposable test database:
NEURON_TEST_POSTGRES_URL=postgres://user:password@localhost/neuron_test mix test
```

The Podman script creates and removes its own temporary Postgres container. The suite verifies the same Ecto migration and FSM operations with Oban's Basic engine.

A live research run additionally requires functioning ZAI, Browser Use, Chromium, and the downloaded local embedding model. Unit fixtures do not verify those services. Infrastructure errors remain errors and must be fixed in the environment.

## Releases

Published tags are never moved. A tag that has been pushed is a fixed point: someone may already have fetched it, pinned a dependency to it, or built from it, and a tag that points somewhere new makes two checkouts of the same name disagree about what they contain. A release that needs a change gets the next tag, not the previous one back.

This was learned by breaking it. `v0.2.3` was force-updated to pick up a later commit on 2026-09-10 and then restored to the commit it was published at, with the change cut as `v0.2.4` instead.

### Cutting a release

Because a tag cannot be corrected once it is pushed, everything about it has to be right before it exists.

```sh
mix neuron.release.check v0.2.5   # fails unless mix.exs declares 0.2.5
mix format --check-formatted
mix test
bash scripts/dgraph_integration.sh
git tag -a v0.2.5 -m "..."
git push origin v0.2.5
```

`mix neuron.release.check TAG` compares the tag you are about to cut against the version in `mix.exs` and fails when they disagree. Run with no argument it checks whatever tags already point at `HEAD` and passes quietly when there are none, so it is safe in CI on every commit.

The check exists because `v0.2.4` was cut at a commit whose `mix.exs` declared `0.2.3`. That tag reports the wrong version to anyone depending on it and cannot be fixed, because fixing it would mean moving it. The version bump is what gets tagged: bump `mix.exs` in its own commit, run the check against the tag you intend, then tag that commit.

The same rule is why git dependencies are pinned to tags rather than branches: `mix.lock` records a commit, but a branch reference lets the next `mix deps.get` resolve to a different one, which is the same problem one layer down.
