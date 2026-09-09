import Config

config :neuron,
  storage: [data_dir: "priv/neuron_data", backend: :rocksdb],
  dgraph: [
    endpoint: System.get_env("NEURON_DGRAPH_ENDPOINT", "localhost:9080"),
    transport: String.to_atom(System.get_env("NEURON_DGRAPH_TRANSPORT", "grpc")),
    enabled: System.get_env("NEURON_DGRAPH_ENABLED", "true") == "true"
  ],
  model: [
    provider: Neuron.Model.ZAI,
    model: "glm-5.3-flash",
    base_url: "https://api.z.ai/api/paas/v4"
  ],
  embeddings: [provider: Neuron.Embedding.Local, model: "BAAI/bge-small-en-v1.5", dimensions: 384],
  browser: [preferred: :local, local: [], browser_use: []],
  limits: [max_runs: 32, max_agents_per_run: 16, max_steps: 200, max_delegation_depth: 4],
  recovery: [enabled: System.get_env("NEURON_RECOVERY_ENABLED", "true") == "true"],
  prompts: [path: "priv/prompts"]

config :neuron, telemetry: [capture_payloads: false]

chromium =
  System.get_env("CHROMIUM") ||
    Enum.find(
      ["/usr/bin/chromium", "/snap/bin/chromium", "/usr/bin/chromium-browser"],
      &File.exists?/1
    )

config :pinocchio,
  browser:
    (if File.exists?(chromium) do
       [executable: chromium, args: ["--headless=new", "--disable-dev-shm-usage"]]
     else
       [executable: nil, endpoint: nil, provider: nil]
     end),
  pool: [size: 4, checkout_timeout: 30_000]

config :mnesia, dir: String.to_charlist("priv/neuron_data")

import_config "#{config_env()}.exs"
