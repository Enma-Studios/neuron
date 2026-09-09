defmodule Neuron.Agent.Worker do
  @callback run(term(), map()) :: {:ok, term()} | {:error, term()}
end

defmodule Neuron.Agent.Echo do
  @behaviour Neuron.Agent.Worker
  def run(input, _context), do: {:ok, input}
end

defmodule Neuron.Agent do
  @behaviour Neuron.Coordinator
  def plan(input, _context), do: {:ok, input}

  def run(plan, context),
    do: plan.worker.run(plan.input, Map.merge(context, Map.take(plan, [:parent_id, :role])))
end
