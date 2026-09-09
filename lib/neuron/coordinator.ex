defmodule Neuron.Coordinator do
  @moduledoc "Behaviour implemented by coordinator profiles."

  @callback plan(input :: term(), context :: map()) :: {:ok, term()} | {:error, term()}
  @callback run(plan :: term(), context :: map()) :: {:ok, term()} | {:error, term()}

  def default, do: Neuron.Coordinator.Default
end

defmodule Neuron.Coordinator.Default do
  @behaviour Neuron.Coordinator

  @impl true
  def plan(input, _context), do: {:ok, input}

  @impl true
  def run(plan, _context), do: {:ok, plan}
end
