import Config

if config_env() == :prod do
  config :neuron,
    storage: [data_dir: System.get_env("NEURON_DATA_DIR", "data/neuron")],
    dgraph: [
      endpoint: System.get_env("NEURON_DGRAPH_ENDPOINT", "localhost:8080"),
      transport: String.to_atom(System.get_env("NEURON_DGRAPH_TRANSPORT", "http")),
      enabled: System.get_env("NEURON_DGRAPH_ENABLED", "true") == "true"
    ],
    model: [
      api_key: System.get_env("ZAI_API_KEY"),
      base_url: System.get_env("ZAI_BASE_URL", "https://api.z.ai/api/paas/v4"),
      model: "glm-5.3-flash"
    ],
    telemetry: [capture_payloads: System.get_env("NEURON_CAPTURE_PAYLOADS", "false") == "true"],
    browser: [
      local: [executable: System.get_env("CHROMIUM", "/usr/bin/chromium")],
      browser_use: [api_key: System.get_env("BROWSER_USE_API_KEY")]
    ]

  config :mnesia, dir: String.to_charlist(System.get_env("NEURON_DATA_DIR", "data/neuron"))

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
    pool: [size: String.to_integer(System.get_env("NEURON_BROWSER_POOL_SIZE", "4"))]
end
