defmodule Neuron.KnowledgeTest do
  use ExUnit.Case, async: true

  test "claims require exact source evidence and reject invented email addresses" do
    document = %{url: "https://company.example/team", markdown: "Ada leads engineering."}

    claim = %{
      "entity_type" => "Person",
      "identity" => "https://linkedin.com/in/ada",
      "predicate" => "title",
      "value" => "Engineering lead",
      "excerpt" => document.markdown,
      "source_url" => document.url
    }

    assert {:ok, [_]} = Neuron.Knowledge.validate_claims(%{"claims" => [claim]}, document)

    assert {:error, _} =
             Neuron.Knowledge.validate_claims(
               %{"claims" => [Map.put(claim, "excerpt", "invented")]},
               document
             )

    assert {:error, _} =
             Neuron.Knowledge.validate_claims(
               %{
                 "claims" => [
                   Map.merge(claim, %{"predicate" => "email", "value" => "ada@company.example"})
                 ]
               },
               document
             )
  end

  test "user assertions outrank newer scraped assertions" do
    user = %{
      "uid" => "1",
      "predicate" => "title",
      "claim_value" => "Founder",
      "assertion_kind" => "user",
      "observed_at" => "2020-01-01",
      "authority" => 1.0
    }

    scraped =
      Map.merge(user, %{
        "uid" => "2",
        "claim_value" => "Engineer",
        "assertion_kind" => "observed",
        "observed_at" => "2026-01-01"
      })

    assert Neuron.Knowledge.resolve([scraped, user])["title"] == user
  end

  test "reciprocal rank fusion rewards candidates in both result sets" do
    lexical = %{"results" => [%{"uid" => "a"}, %{"uid" => "b"}]}
    semantic = %{"results" => [%{"uid" => "b"}, %{"uid" => "c"}]}
    assert [%{"uid" => "b"}, _, _] = Neuron.GraphSearch.fuse(lexical, semantic)
  end
end
