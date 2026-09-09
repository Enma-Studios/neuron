defmodule Neuron.DgraphIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    connection = Neuron.Dgraph.connection()
    assert is_pid(connection), "integration requires a configured Dgraph connection"
    {:ok, connection: connection}
  end

  test "ingestion preserves full Markdown and its first observation, reconciles facts and embeds people",
       %{connection: connection} do
    assert {:ok, _} = Neuron.Graph.Schema.apply(connection)
    nonce = Ecto.UUID.generate()
    url = "https://buyer-#{nonce}.example/team"
    first = DateTime.utc_now() |> DateTime.add(-86400)

    doc = %{
      url: url,
      title: "Team",
      markdown: "Ada is CTO. ada@buyer.example",
      fetched_at: first,
      published_at: nil
    }

    assert {:ok, id} = Neuron.Knowledge.save_document(doc, connection: connection)

    assert {:ok, ^id} =
             Neuron.Knowledge.save_document(%{doc | fetched_at: DateTime.utc_now()},
               connection: connection
             )

    assert {:ok, %{"snapshots" => [snapshot]}} =
             Neuron.Graph.query(
               "query snapshot($id: string) { snapshots(func: eq(external_id, $id)) { markdown observed_at } }",
               %{"$id" => id},
               connection: connection
             )

    assert snapshot["markdown"] == doc.markdown
    assert {:ok, date, _} = DateTime.from_iso8601(snapshot["observed_at"])
    assert DateTime.diff(date, first) == 0
    identity = "https://linkedin.com/in/#{nonce}"

    claim = %{
      entity_type: "Person",
      identity: identity,
      predicate: "name",
      value: "Ada",
      excerpt: "Ada",
      source_url: url
    }

    assert :ok = Neuron.Knowledge.ingest([claim], doc, id, connection: connection)
    assert :ok = Neuron.Knowledge.index_document(doc, id, connection: connection)

    assert {:ok, %{"people" => [person]}} =
             Neuron.Graph.query(
               "query person($url: string) { people(func: eq(profile_url, $url)) { name embedding_e5_384 knowledge_json assertions { excerpt } } }",
               %{"$url" => identity},
               connection: connection
             )

    assert person["name"] == "Ada"
    assert person["embedding_e5_384"] != nil
    assert Jason.decode!(person["knowledge_json"])["name"] == "Ada"
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
