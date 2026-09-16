import Config

if config_env() == :prod do
  config :neuron,
    dgraph: [
      endpoint: System.get_env("NEURON_DGRAPH_ENDPOINT", "localhost:9080"),
      transport: String.to_atom(System.get_env("NEURON_DGRAPH_TRANSPORT", "grpc")),
      enabled: System.get_env("NEURON_DGRAPH_ENABLED", "true") == "true"
    ],
    model: [
      api_key: System.get_env("ZAI_API_KEY"),
      base_url: System.get_env("ZAI_BASE_URL", "https://api.z.ai/api/paas/v4"),
      model: "glm-5.3-flash"
    ],
    telemetry: [capture_payloads: System.get_env("NEURON_CAPTURE_PAYLOADS", "false") == "true"],
    search: [
      engines: [Neuron.Search.DuckDuckGo, Neuron.Search.Brave],
      brave: [api_key: System.get_env("BRAVE_SEARCH_API_KEY")]
    ],
    browser: [
      fleet: [
        sessions: String.to_integer(System.get_env("NEURON_FLEET_SESSIONS", "1")),
        pages_per_session: String.to_integer(System.get_env("NEURON_FLEET_PAGES", "4")),
        # Restated because this block replaces the one in config.exs whole.
        timeout: 45_000
      ],
      browser_use: [
        api_key: System.get_env("BROWSER_USE_API_KEY"),
        profile_id: System.get_env("BROWSER_USE_PROFILE_ID")
      ]
    ]

  config :neuron, Neuron.Repo, database: System.fetch_env!("NEURON_DATABASE")
end
