defmodule Neuron.Search.BraveTest do
  use ExUnit.Case, async: false

  alias Neuron.Search.Brave

  # A real response, captured from the live API on 2026-09-11 for the query
  # `"meet the team" "co-founder" CTO SaaS company`, saved verbatim. Every
  # field the API sent is here, including the ones Neuron ignores.
  #
  # Edge cases that a real response does not happen to contain are inline
  # below as synthetic maps, labelled as such, rather than smuggled into the
  # capture.
  @fixture "test/support/fixtures/brave_web_search.json"

  defp body, do: @fixture |> File.read!() |> Jason.decode!()

  defp task,
    do: %{id: {Brave, "q"}, engine: Brave, query: "acme CTO", url: Brave.search_url("acme CTO")}

  setup do
    original = Application.get_env(:neuron, :search, [])
    on_exit(fn -> Application.put_env(:neuron, :search, original) end)
    :ok
  end

  defp with_key(key) do
    config = Application.get_env(:neuron, :search, [])
    Application.put_env(:neuron, :search, Keyword.put(config, :brave, api_key: key))
  end

  test "parses the captured response into results" do
    assert [first, second] = Brave.parse(body())

    assert first.title == "Meet the Team: James Ciesielski, Co-founder and CTO | Rewind"
    assert first.url =~ "https://rewind.com/blog/meet-the-team-james-ciesielski"
    assert second.url == "https://companyon.vc/team/"

    # The live API marks up matched terms. Tags are stripped rather than
    # reaching a lead title as markup.
    assert first.snippet =~ "James Ciesielski"
    refute first.snippet =~ "<strong>"
    refute first.snippet =~ "</strong>"
  end

  test "drops a result whose URL is not one, and deduplicates" do
    # Synthetic, not captured: a real response did not contain either case.
    body = %{
      "web" => %{
        "results" => [
          %{"title" => "Team", "url" => "https://acme.example/team", "description" => "a"},
          %{"title" => "No URL", "url" => "not-a-url", "description" => "b"},
          %{"title" => "Team again", "url" => "https://acme.example/team", "description" => "c"}
        ]
      }
    }

    assert [%{url: "https://acme.example/team"}] = Brave.parse(body)
  end

  test "parses an equivalent JSON string, and anything unexpected into nothing" do
    assert Brave.parse(File.read!(@fixture)) == Brave.parse(body())

    for junk <- ["", "not json", "{}", %{}, %{"web" => %{}}, nil] do
      assert Brave.parse(junk) == []
    end
  end

  test "builds the transcript a browser page would have produced" do
    transcript = Brave.build_transcript(task(), body())

    assert transcript.engine == Brave
    assert transcript.query == "acme CTO"
    assert transcript.url == task().url

    # Every URL the model may select is in links, and nothing else is, so
    # the harvest's exact-URL contract holds without a browser.
    assert Enum.map(transcript.links, & &1.href) == Enum.map(Brave.parse(body()), & &1.url)
    assert length(transcript.links) == 2

    assert transcript.markdown =~ "](https://companyon.vc/team/)"
    assert transcript.text =~ "James Ciesielski"

    # A keyed API returns no document, so there is no wall to read out of one.
    assert transcript.document == ""
    assert Neuron.Search.wall_reason(transcript) == nil
  end

  test "a transcript harvests through the ordinary path" do
    transcript = Brave.build_transcript(task(), body())

    assert {:ok, [result]} =
             Neuron.Search.Harvest.harvest(transcript,
               model_provider: Neuron.SearchTest.BraveHarvestModel
             )

    assert result.url == "https://companyon.vc/team/"
  end

  test "the exact-URL contract holds over a keyed transcript too" do
    # A keyed engine changes where the transcript comes from, not the rule
    # that the model may only select from what is in it.
    transcript = Brave.build_transcript(task(), body())

    assert {:error, {:invalid_model_output, _}} =
             Neuron.Search.Harvest.harvest(transcript,
               model_provider: Neuron.SearchTest.HallucinatingModel
             )
  end

  describe "availability" do
    test "absent without a key, present with one, from either source" do
      env = System.get_env("BRAVE_SEARCH_API_KEY")
      on_exit(fn -> if env, do: System.put_env("BRAVE_SEARCH_API_KEY", env) end)

      # Neither source: absent from the round rather than failing in it.
      with_key(nil)
      System.delete_env("BRAVE_SEARCH_API_KEY")
      refute Brave.available?()
      refute Brave in Neuron.Search.engines()

      # The environment alone is enough, which is how a host supplies it.
      System.put_env("BRAVE_SEARCH_API_KEY", "from-the-environment")
      assert Brave.api_key() == "from-the-environment"
      assert Brave in Neuron.Search.engines()

      # Configuration wins over the environment when both are set.
      with_key("from-configuration")
      assert Brave.api_key() == "from-configuration"
      assert Brave in Neuron.Search.engines()
    end

    test "an engine that does not declare availability is assumed available" do
      assert Neuron.Search.Engine.available?(Neuron.Search.Yandex)
      assert Neuron.Search.Engine.available?(Neuron.Search.DuckDuckGo)
    end

    test "Brave is the keyed engine; the browser engines are not" do
      assert Neuron.Search.Engine.keyed?(Brave)
      refute Neuron.Search.Engine.keyed?(Neuron.Search.Yandex)
      refute Neuron.Search.Engine.keyed?(Neuron.Search.DuckDuckGo)
    end
  end

  test "exposes the same behaviour surface as every other engine" do
    assert Brave.kind() == :web
    assert Brave.keywords("acme founder") == "acme founder"
    assert String.starts_with?(Brave.search_url("acme founder"), "https://api.search.brave.com/")
    assert Brave.search_url("acme founder") =~ "q=acme+founder"
    assert is_list(Brave.parse("{}"))
    assert Brave.blocked?("{}") == false
    assert Brave.gated?("{}") == false
  end

  @tag :integration
  test "answers a live query" do
    key = System.get_env("BRAVE_SEARCH_API_KEY")

    if is_nil(key) or key == "" do
      flunk("BRAVE_SEARCH_API_KEY must be set to run the live Brave test")
    end

    {:ok, _} = Application.ensure_all_started(:req)
    assert {:ok, transcript} = Brave.transcript(task(), [])

    assert transcript.links != [], "a live query returned no results"
    assert Enum.all?(transcript.links, &String.starts_with?(&1.href, ["http://", "https://"]))
    assert Neuron.Search.wall_reason(transcript) == nil
  end
end
