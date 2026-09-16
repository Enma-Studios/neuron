defmodule Neuron.MixProject do
  use Mix.Project

  def project do
    [
      app: :neuron,
      version: "0.2.16",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      aliases: [test: ["neuron.migrate", "test"]],
      source_url: "https://github.com/Enma-Studios/neuron",
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      mod: {Neuron.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl]
    ]
  end

  defp deps do
    base_deps = [
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:postgrex, "~> 0.21"},
      {:oban, "~> 2.24"},
      {:gen_stage, "~> 1.3"},
      {:bumblebee, "~> 0.7"},
      {:exla, "~> 0.12"},
      {:owl, "~> 0.13"},
      {:telemetry, "~> 1.3"},
      {:req, "~> 0.5"},
      {:dlex, github: "Enma-Studios/dlex", tag: "v0.1.0", optional: false},
      {:htmd, "~> 0.2", optional: false}
    ]

    pinocchio =
      {:pinocchio, git: "git@github.com:Enma-Studios/pinocchio.git", tag: "v0.1.0"}

    base_deps ++ [pinocchio]
  end
end
