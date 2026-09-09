defmodule Neuron.GraphUpsertTest do
  use ExUnit.Case, async: true

  test "stable references resolve to the same upsert variable" do
    facts = %{
      "uid" => "_:org",
      "people" => [%{"uid" => "_:person", "employer" => %{"uid" => "_:org"}}]
    }

    {query, payload} = Neuron.Graph.upsert_request(facts)
    assert query =~ "eq(external_id,"
    assert payload["uid"] == hd(payload["people"])["employer"]["uid"]
    assert payload["external_id"] == "_:org"
    assert Neuron.Graph.upsert_request(facts) == {query, payload}
  end
end
