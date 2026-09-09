import Config

config :neuron, storage: [data_dir: "priv/neuron_data/dev"]

config :mnesia, dir: String.to_charlist("priv/neuron_data/dev")
