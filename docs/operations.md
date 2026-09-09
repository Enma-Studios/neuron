# Operations runbook

See the [migration guide](migrations.md) for the complete versioning model,
deployment sequence, and instructions for adding a migration.

## Development boot

```sh
git clone git@github.com:Enma-Studios/neuron.git
cd neuron
mix deps.get
mix compile
iex -S mix
```

Pinocchio is a private SSH dependency. Test the credential path before running
Mix:

```sh
ssh -T git@github.com
git ls-remote git@github.com:Enma-Studios/pinocchio.git main
```

Keep `ZAI_API_KEY` and `BROWSER_USE_API_KEY` in a secret manager or process
environment. Never commit them to `config/*.exs` or `mise.local.toml`.

## Dgraph

The application uses Dgraph's gRPC endpoint at `localhost:9080` by default.
The repeatable local check is:

```sh
scripts/dgraph_integration.sh
```

The script starts a disposable Dgraph v25.4.0 container, waits for health,
enables Dgraph for the test environment, applies the schema, writes a fact,
queries it, and removes the container. To keep Dgraph running for manual
inspection, run Podman yourself and set `NEURON_DGRAPH_ENDPOINT` and
`NEURON_DGRAPH_TRANSPORT` before
starting Neuron.

When Dgraph is down, `Neuron.Dgraph` keeps the application alive with an
unavailable connection. Graph-backed runs return a structured graph error;
provider-isolated checks can pass `persist: false`.

## Mnesia data

Mnesia directories must be persistent in production. The application creates
the schema table as `disc_copies` before creating Neuron tables. The configured
default backend uses `mnesia_rocksdb` for all Neuron data tables. If the native
adapter cannot load, startup and migration fail until the host environment is
fixed.

```sh
export NEURON_DATA_DIR=/var/lib/neuron
mix deps.get
```

Back up the configured data directory with the application stopped. Do not
delete it during a running release. For disposable tests, use the test
directory or a clean temporary directory.

Run the Mnesia schema migration after provisioning a new data directory or
upgrading Neuron:

```sh
mix neuron.mnesia.migrate --data-dir /var/lib/neuron
```

Apply the Dgraph predicates and indexes separately. The default gRPC listener
is `localhost:9080`; select the HTTP listener at `localhost:8080` explicitly
with `--transport http`:

```sh
mix neuron.dgraph.migrate
mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
mix neuron.dgraph.migrate --endpoint localhost:8080 --transport http
```

Migration execution is versioned. Each successful version is written to the
`neuron_migration` Mnesia table, so rerunning a task applies pending versions
and reconciles the current Dgraph schema. Inspect the applied records from IEx:

```elixir
Neuron.Storage.migration_status()
Neuron.Storage.migration_status(:dgraph)
```

## Browser health

Check the executable selected by Neuron:

```sh
command -v chromium chromium-browser google-chrome
echo "$CHROMIUM"
```

The configuration checks `CHROMIUM`, `/usr/bin/chromium`,
`/snap/bin/chromium`, and `/usr/bin/chromium-browser`. A missing or failed
local session produces a browser blockage event and invokes Browser Use when
`BROWSER_USE_API_KEY` is available.

The Pinocchio pool size is controlled by `NEURON_BROWSER_POOL_SIZE`. Keep it
below the host's CPU/memory capacity; Browser Use sessions also consume remote
provider capacity.

## Live smoke checks

```sh
# Local Chromium
mix run -e 'IO.inspect(Neuron.Browser.fetch("https://example.com", provider: :local))'

# DuckDuckGo through Browser Use
mix run -e 'IO.inspect(Neuron.Search.DuckDuckGo.search("Elixir OTP"))'

# Full search -> explore -> score path
mix run -e 'fit = %{requirements: [%{category: "industry", description: "software"}]}; IO.inspect(Neuron.Intelligence.discover("software companies", fit))'

# Z.AI completion (glm-5.3-flash only)
mix run -e 'IO.inspect(Neuron.Model.ZAI.complete([%{"role" => "user", "content" => "Say hello"}]))'
```

These commands use external services and may incur provider usage. A Z.AI
HTTP 429 indicates account quota/resource-package state; the request is always
for `glm-5.3-flash`.

## Campaign operation

```elixir
campaign = %{
  organization: "example.com",
  field: "B2B cybersecurity",
  offer: "Security assessment partnership",
  target_roles: ["CTO", "VP Engineering"],
  geography: ["US", "Canada"],
  exclusions: ["personal sources", "free-mail addresses"],
  lead_count: 3
}

{:ok, result} = Neuron.run(Neuron.Coordinator.Campaign, campaign, timeout: 300_000)
result.leads
```

For URL-first intake, call `Neuron.Campaign.intake(%{url: url})` and show the
returned questions. An `:approval_required` response contains distinct
proposals; call `Neuron.Campaign.approve/2` after the operator selects them.
`action: :different_campaign` discards URL proposals and starts the bounded
intake again. `lead_count` and `max_attempts` control the off-agent unique
lead counter.

## Telemetry handlers

Attach handlers before starting work when running a diagnostic shell:

```elixir
:telemetry.attach(
  "neuron-debug",
  [:neuron, :browser, :blocked],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

For production, forward events to the service's normal Telemetry exporter.
Keep payload capture disabled unless the destination is access-controlled.

## Failure handling

- **Run failed:** inspect `Neuron.get_run/1` and `Neuron.events/1`; the error
  and final state are durable.
- **Agent failed:** inspect `Neuron.get_agent/1` and the parent run events.
- **Browser blocked:** inspect provider attempt/block events; retry with
  `provider: :browser_use` to isolate local Chromium problems.
- **Graph write failed:** restore Dgraph connectivity and rerun the operation,
  or use `persist: false` for a provider-isolated check.
- **Z.AI 401/429:** rotate the secret or restore the Z.AI resource package.
- **Output shape confirmation:** inspect `research:confirm_output` telemetry.
  Neuron performs one repair pass with the Ecto errors and returns a structured
  `:invalid_research_result` error if the response remains invalid.
- **Native dependency build failure:** disable the relevant `NEURON_ENABLE_*`
  flag and use the portable backend while fixing the build host.
