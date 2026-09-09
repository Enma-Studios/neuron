defmodule Neuron.DgraphIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    case Neuron.Dgraph.connection() do
      connection when is_pid(connection) -> {:ok, connection: connection}
      _ -> {:skip, "Dgraph is not configured or available"}
    end
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

    assert {:ok, _} =
             Neuron.Graph.query(
               "query by_name($name: string) { by_name(func: eq(name, $name)) { uid name } }",
               %{"$name" => "Neuron Integration #{nonce}"},
               connection: connection
             )
  end
end
