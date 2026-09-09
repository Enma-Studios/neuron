defmodule Neuron.RunTest do
  use ExUnit.Case, async: false

  test "runs a coordinator and delegated agent with durable events" do
    id = "run-#{System.unique_integer([:positive])}"
    assert {:ok, ^id} = Neuron.start_run(Neuron.Coordinator.Default, %{goal: "discover"}, id: id)
    assert {:ok, agent_id} = Neuron.spawn_agent(id, :enrich, Neuron.Agent.Echo, %{name: "Acme"})

    Process.sleep(50)
    assert %{status: :complete, result: %{goal: "discover"}} = Neuron.get_run(id)
    assert %{status: :complete, result: %{name: "Acme"}} = Neuron.get_agent(agent_id)
    assert length(Neuron.events(id)) >= 7
  end
end
