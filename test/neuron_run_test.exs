defmodule Neuron.RunTest do
  use ExUnit.Case, async: false

  setup_all do
    unless Process.whereis(Neuron.RunSupervisor) do
      Application.put_env(:neuron, :storage, data_dir: "tmp/neuron_data/test", backend: :mnesia)
      {:ok, _} = Neuron.Application.start(:normal, [])
    end

    :ok
  end

  test "runs a coordinator and delegated agent with durable events" do
    id = "run-#{System.unique_integer([:positive])}"
    assert {:ok, ^id} = Neuron.start_run(Neuron.Coordinator.Default, %{goal: "discover"}, id: id)
    assert {:ok, agent_id} = Neuron.spawn_agent(id, :enrich, Neuron.Agent.Echo, %{name: "Acme"})

    Process.sleep(50)
    assert %{status: :complete, result: %{goal: "discover"}} = Neuron.get_run(id)
    assert %{status: :complete, result: %{name: "Acme"}} = Neuron.get_agent(agent_id)
    assert length(Neuron.events(id)) >= 7

    assert {:ok, outbox_id} = Neuron.Outbox.enqueue(id, :lead_discovered, %{name: "Acme"})
    assert {:atomic, pending} = Neuron.Storage.pending_outbox()

    assert Enum.any?(pending, fn {:neuron_outbox, key, ^id, :lead_discovered, _payload, :pending,
                                  _, _} ->
             key == outbox_id
           end)
  end

  test "blocking run returns lead fields at the response level" do
    id = "run-result-#{System.unique_integer([:positive])}"

    assert {:ok, response} =
             Neuron.run(Neuron.Coordinator.Default, %{leads: [%{name: "Ada"}]}, id: id)

    assert response.id == id
    assert response.result.leads == [%{name: "Ada"}]
    assert response.leads == [%{name: "Ada"}]
  end
end
