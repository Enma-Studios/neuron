import Config

config :neuron,
  storage: [data_dir: "tmp/neuron_data/test"],
  dgraph: [enabled: false],
  model: [provider: Neuron.Model.Stub],
  embeddings: [provider: Neuron.Embedding.Stub]

config :mnesia, dir: String.to_charlist("tmp/neuron_data/test")
