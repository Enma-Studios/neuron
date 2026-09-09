defmodule Neuron.DgraphIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    connection = Neuron.Dgraph.connection()
    assert is_pid(connection), "integration requires a configured Dgraph connection"
    {:ok, connection: connection}
  end

  test "applies the graph schema and round trips a domain fact", %{connection: connection} do
    assert {:ok, _} = Neuron.Graph.Schema.apply(connection)

    nonce = System.unique_integer([:positive])
    uid = "_:neuron_integration_#{nonce}"

    assert :ok =
             Neuron.Graph.upsert(
               %{"uid" => uid, "name" => "Neuron Integration #{nonce}"},
               connection: connection
             )

    assert :ok =
             Neuron.Graph.upsert(%{"uid" => uid, "name" => "Neuron Integration #{nonce}"},
               connection: connection
             )

    assert {:ok, response} =
             Neuron.Graph.query(
               "query by_name($name: string) { by_name(func: eq(name, $name)) { uid name } }",
               %{"$name" => "Neuron Integration #{nonce}"},
               connection: connection
             )

    assert [%{"uid" => _, "name" => _}] = response["by_name"]
  end
end
