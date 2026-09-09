import Config

config :neuron,
  storage: [data_dir: "tmp/neuron_data/test"],
  model: [provider: Neuron.Model.Stub],
  embeddings: [provider: Neuron.Embedding.Stub]
