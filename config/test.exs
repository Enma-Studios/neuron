import Config

config :neuron,
  storage: [data_dir: "tmp/neuron_data/test"],
  dgraph: [
    enabled: System.get_env("NEURON_DGRAPH_ENABLED", "false") == "true",
    endpoint: System.get_env("NEURON_DGRAPH_ENDPOINT", "localhost:9080"),
    transport: String.to_atom(System.get_env("NEURON_DGRAPH_TRANSPORT", "grpc"))
  ],
  model: [provider: Neuron.Model.Stub],
  embeddings: [provider: Neuron.Embedding.Stub]

config :mnesia, dir: String.to_charlist("tmp/neuron_data/test")

config :pinocchio, browser: [executable: nil, endpoint: nil, provider: nil]

config :ex_unit, exclude: [integration: true]
