import Config

if config_env() == :prod do
  config :neuron,
    storage: [data_dir: System.get_env("NEURON_DATA_DIR", "data/neuron")],
    model: [
      api_key: System.get_env("ZAI_API_KEY"),
      base_url: System.get_env("ZAI_BASE_URL", "https://api.z.ai/api/paas/v4"),
      model: System.get_env("ZAI_MODEL", "glm-5.3-flash")
    ],
    telemetry: [capture_payloads: System.get_env("NEURON_CAPTURE_PAYLOADS", "false") == "true"],
    browser: [
      local: [executable: System.get_env("CHROMIUM", "/usr/bin/chromium")],
      browser_use: [api_key: System.get_env("BROWSER_USE_API_KEY")]
    ]

  config :mnesia, dir: String.to_charlist(System.get_env("NEURON_DATA_DIR", "data/neuron"))
end
