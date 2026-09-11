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

    # Every observed assertion must be traceable to the document it was read
    # from. Ten campaign runs once produced 319 assertions and not one source
    # edge, which left no way to check an excerpt against its own source.
    # Scoped to this ingestion's own document rather than the whole database,
    # so the assertion is about the code under test and not about whatever
    # else happens to be in a shared instance.
    assert {:ok, %{"orphans" => orphans}} =
             Neuron.Graph.query(
               "query orphans($url: string) { orphans(func: type(Assertion)) @filter(eq(url, $url) AND eq(assertion_kind, \"observed\") AND NOT has(sources)) { uid predicate url } }",
               %{"$url" => Neuron.Knowledge.canonical_url(url)},
               connection: connection
             )

    assert orphans == [], "observed assertions with no source edge: #{inspect(orphans)}"

    assert {:ok, %{"cited" => [assertion]}} =
             Neuron.Graph.query(
               "query cited($url: string) { cited(func: type(Assertion)) @filter(eq(url, $url) AND eq(claim_value, \"Ada\")) { excerpt sources { url } } }",
               %{"$url" => Neuron.Knowledge.canonical_url(url)},
               connection: connection
             )

    # The edge points at the document the claim was actually read from, so
    # the excerpt can be checked against that source rather than against the
    # whole corpus.
    assert [%{"url" => cited_url}] = assertion["sources"]
    assert cited_url == Neuron.Knowledge.canonical_url(url)
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
