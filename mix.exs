defmodule Neuron.MixProject do
  use Mix.Project

  def project do
    [
      app: :neuron,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:req, "~> 0.5"},
      {:dlex, github: "Enma-Studios/dlex", branch: "master", optional: true},
      {:pinocchio, github: "Enma-Studios/pinocchio", branch: "main", optional: true},
      {:htmd, "~> 0.2", optional: true},
      {:mnesia_rocksdb,
       github: "aeternity/mnesia_rocksdb", branch: "master", manager: :rebar3, optional: true},
      {:nx, "~> 0.9", optional: true},
      {:bumblebee, "~> 0.7", optional: true},
      {:exla, "~> 0.9", optional: true}
    ]
  end
end
