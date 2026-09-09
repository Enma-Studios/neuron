defmodule Neuron.AgentSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_agent(id, run_id, parent_id, role, worker, input, opts) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Neuron.Agent, {id, run_id, parent_id, role, worker, input, opts}}
    )
  end
end
