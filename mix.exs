defmodule Neuron.MixProject do
  use Mix.Project

  def project do
    [
      app: :neuron,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/Enma-Studios/neuron",
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      mod: {Neuron.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl, :mnesia]
    ]
  end

  defp deps do
    base_deps = [
      {:jason, "~> 1.4"},
      {:ecto, "~> 3.12"},
      {:telemetry, "~> 1.3"},
      {:req, "~> 0.5"},
      {:dlex, github: "Enma-Studios/dlex", branch: "master", optional: true},
      {:htmd, "~> 0.2", optional: true}
    ]

    rocksdb_deps =
      if System.get_env("NEURON_ENABLE_ROCKSDB") == "true" do
        [
          {:mnesia_rocksdb,
           github: "aeternity/mnesia_rocksdb", branch: "master", manager: :rebar3}
        ]
      else
        []
      end

    ml_deps =
      if System.get_env("NEURON_ENABLE_LOCAL_ML") == "true" do
        [{:nx, "~> 0.9"}, {:bumblebee, "~> 0.7"}, {:exla, "~> 0.9"}]
      else
        []
      end

    pinocchio =
      {:pinocchio, git: "git@github.com:Enma-Studios/pinocchio.git", branch: "main"}

    base_deps ++ rocksdb_deps ++ ml_deps ++ [pinocchio]
  end
end
