defmodule Neuron.RunSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_run(id, profile, input, opts) do
    child = {Neuron.Run, {id, profile, input, opts}}
    DynamicSupervisor.start_child(__MODULE__, child)
  end
end
