defmodule Neuron.RunTest do
  use ExUnit.Case, async: false

  defmodule Guarded do
    use Neuron.FSM
    state(:pending)
    state(:done)
    transition(:finish, from: :pending, to: :done, guard: :approved?)
    def approved?(_, payload), do: payload[:approved] == true
  end

  test "runs a coordinator and delegated agent with durable results and events" do
    assert {:ok, id} = Neuron.start_run(Neuron.Coordinator.Default, %{leads: [%{name: "Ada"}]})
    assert {:ok, agent_id} = Neuron.spawn_agent(id, :enrich, Neuron.Agent.Echo, %{name: "Acme"})
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators, with_recursion: true)
    assert %{status: :complete, leads: [%{name: "Ada"}]} = Neuron.get_run(id)
    assert %{status: :complete, result: %{name: "Acme"}} = Neuron.get_agent(agent_id)
    assert Enum.map(Neuron.events(id), & &1.event) == ["created", "planned", "finished"]
    assert {:ok, %{leads: [%{name: "Ada"}]}} = Neuron.await_run(id)
  end

  test "stale jobs cannot execute cancelled runs" do
    {:ok, id} = Neuron.start_run(Neuron.Coordinator.Default, %{goal: "cancel"})
    assert {:ok, _} = Neuron.cancel_run(id)
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators, with_recursion: true)
    assert %{status: :cancelled, version: 1, result: nil} = Neuron.get_run(id)
    assert {:error, :stale} = Neuron.FSM.send(id, :planned, %{}, version: 0)
    assert length(Neuron.events(id)) == 2
  end

  test "guards reject without mutating state or history" do
    {:ok, machine} = Neuron.FSM.create(Guarded, %{})
    assert Neuron.FSM.allowed_events(machine.id) == [:finish]
    assert {:error, :guard_rejected} = Neuron.FSM.send(machine.id, :finish)
    assert Neuron.FSM.state(machine.id) == "pending"
    assert length(Neuron.events(machine.id)) == 1
    assert {:ok, %{version: 1}} = Neuron.FSM.send(machine.id, :finish, %{approved: true})
  end
end
