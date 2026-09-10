defmodule Neuron.KnowledgeTest do
  use ExUnit.Case, async: true

  test "claims require exact source evidence and drop invented email addresses" do
    document = %{
      url: "https://company.example/team",
      markdown: "Ada leads engineering. https://linkedin.com/in/ada"
    }

    claim = %{
      "entity_type" => "Person",
      "identity" => "https://linkedin.com/in/ada",
      "predicate" => "title",
      "value" => "Engineering lead",
      "excerpt" => document.markdown,
      "source_url" => document.url
    }

    assert {:ok, [_]} = Neuron.Knowledge.validate_claims(%{"claims" => [claim]}, document)

    # Flawed claims are dropped while the rest of the batch survives.
    assert {:ok, []} =
             Neuron.Knowledge.validate_claims(
               %{"claims" => [Map.put(claim, "excerpt", "invented")]},
               document
             )

    assert {:ok, []} =
             Neuron.Knowledge.validate_claims(
               %{
                 "claims" => [
                   Map.merge(claim, %{"predicate" => "email", "value" => "ada@company.example"})
                 ]
               },
               document
             )

    assert {:ok, []} =
             Neuron.Knowledge.validate_claims(%{"claims" => [123]}, document)
  end

  test "organizations may be identified by their bare domain" do
    document = %{
      url: "https://efuturesworld.com/",
      markdown: "Software Development Company in Sri Lanka | EFutures"
    }

    claim = %{
      "entity_type" => "Organization",
      "identity" => "efuturesworld.com",
      "predicate" => "description",
      "value" => "Software development company in Sri Lanka",
      "excerpt" => "Software Development Company in Sri Lanka | EFutures",
      "source_url" => document.url
    }

    assert {:ok, [_]} = Neuron.Knowledge.validate_claims(%{"claims" => [claim]}, document)
  end

  test "a flawed claim does not discard its valid siblings" do
    document = %{
      url: "https://company.example/team",
      markdown: "Ada leads engineering. https://linkedin.com/in/ada"
    }

    good = %{
      "entity_type" => "Person",
      "identity" => "https://linkedin.com/in/ada",
      "predicate" => "title",
      "value" => "Engineering lead",
      "excerpt" => "Ada leads engineering.",
      "source_url" => document.url
    }

    bad = %{"entity_type" => "Person", "identity" => "not a url or claim"}

    assert {:ok, [kept]} =
             Neuron.Knowledge.validate_claims(%{"claims" => [bad, good]}, document)

    assert kept[:identity] == "https://linkedin.com/in/ada"
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
