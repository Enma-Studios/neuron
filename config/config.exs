import Config

config :neuron,
  storage: [data_dir: "priv/neuron_data", backend: :mnesia],
  model: [provider: Neuron.Model.ZAI, model: "glm-5.3-flash", base_url: "https://api.z.ai/api/paas/v4"],
  embeddings: [provider: Neuron.Embedding.Local, model: "BAAI/bge-small-en-v1.5", dimensions: 384],
  browser: [preferred: :local, local: [], browser_use: []],
  limits: [max_runs: 32, max_agents_per_run: 16, max_steps: 200, max_delegation_depth: 4],
  prompts: [path: "priv/prompts"]

config :neuron, telemetry: [capture_payloads: false]

import_config "#{config_env()}.exs"
