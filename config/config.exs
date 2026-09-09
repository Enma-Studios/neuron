import Config

config :neuron,
  repo: Neuron.Repo,
  oban_name: Neuron.Oban,
  start_repo: true,
  start_oban: true,
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
  embeddings: [
    provider: Neuron.Embedding.Local,
    model: "intfloat/multilingual-e5-small",
    revision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
    directory: "models/multilingual-e5-small",
    dimensions: 384,
    batch_size: 4,
    sequence_length: 512
  ],
  browser: [
    preferred: :local,
    local: [],
    fleet: [sessions: 2, pages_per_session: 8, timeout: 45_000],
    browser_use: [
      profile_id: System.get_env("BROWSER_USE_PROFILE_ID")
    ]
  ],
  search: [
    engines: [
      Neuron.Search.DuckDuckGo,
      Neuron.Search.Google,
      Neuron.Search.Yandex,
      Neuron.Search.LinkedIn,
      Neuron.Search.X,
      Neuron.Search.Reddit
    ]
  ],
  limits: [max_runs: 32],
  prompts: []

config :neuron, telemetry: [capture_payloads: false]

chromium =
  System.get_env("CHROMIUM") ||
    Enum.find(
      ["/usr/bin/chromium", "/snap/bin/chromium", "/usr/bin/chromium-browser"],
      &File.exists?/1
    )

config :pinocchio,
  browser:
    (if chromium do
       [executable: chromium, args: ["--headless=new", "--disable-dev-shm-usage"]]
     else
       [executable: nil, endpoint: nil, provider: nil]
     end),
  pool: [size: 4, checkout_timeout: 30_000]

config :neuron, ecto_repos: [Neuron.Repo]

config :neuron, Neuron.Repo,
  database: System.get_env("NEURON_DATABASE", "neuron.db"),
  pool_size: 5,
  busy_timeout: 15_000,
  journal_mode: :wal

config :neuron, :oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  lifeline: [rescue_after: {1, :hour}],
  queues: [orchestrators: 4, agents: 8],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

import_config "#{config_env()}.exs"
