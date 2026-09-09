import Config

config :neuron,
  dgraph: [
    enabled: System.get_env("NEURON_DGRAPH_ENABLED", "false") == "true",
    endpoint: System.get_env("NEURON_DGRAPH_ENDPOINT", "localhost:9080"),
    transport: String.to_atom(System.get_env("NEURON_DGRAPH_TRANSPORT", "grpc"))
  ],
  model: [provider: Neuron.Model.Stub],
  embeddings: [provider: Neuron.Embedding.Stub]

config :neuron, Neuron.Repo, database: "tmp/neuron_test.db"
config :neuron, :oban, testing: :manual, queues: false, plugins: false

config :pinocchio, browser: [executable: nil, endpoint: nil, provider: nil]

config :ex_unit, exclude: [integration: true]

config :logger, level: :warning

if url = System.get_env("NEURON_TEST_POSTGRES_URL") do
  config :neuron, repo: Neuron.Test.PostgresRepo
  config :neuron, Neuron.Test.PostgresRepo, url: url, pool_size: 5
  config :neuron, :oban, engine: Oban.Engines.Basic, notifier: Oban.Notifiers.Postgres
end
