defmodule Neuron.Application do
  @moduledoc "OTP entrypoint for durable agent runs and the shared domain graph."

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Neuron.Storage, []},
      {Neuron.Dgraph, []},
      {Neuron.RunRegistry, []},
      {Neuron.RunSupervisor, []},
      {Neuron.AgentSupervisor, []},
      {Neuron.Recovery, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Neuron.Supervisor)
  end
end
