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
