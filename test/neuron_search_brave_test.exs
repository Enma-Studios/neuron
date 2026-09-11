defmodule Neuron.Search.BraveTest do
  use ExUnit.Case, async: false

  alias Neuron.Search.Brave

  # A response in the shape Brave's Web Search API documents: `web.results`
  # carrying `title`, `url` and `description`. Constructed from the
  # documented shape rather than captured from a live call, because no key
  # was available when this was written. Replace it with a captured response
  # the first time the live test below is run with one.
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

  test "parses the documented response into results" do
    assert [first, second, third] = Brave.parse(body())

    assert first.title == "About us | Rewind"
    assert first.url == "https://rewind.com/about/"
    assert first.snippet =~ "James Ciesielski, co-founder and CTO"

    # `&amp;` is decoded, because the shared engine helper handles it.
    assert third.snippet =~ "Eric Klinker, Co-Founder & CEO"
    assert second.snippet =~ "CEO & Co-Founder"

    # `&mdash;` is not, and passes through as written. Recorded here as the
    # behaviour that exists rather than the behaviour one might assume:
    # `Neuron.Search.Engine.html_entities/1` decodes six entities and this
    # is not one of them, so a real title carrying it reaches a lead intact.
    # Worth widening that helper, and not as part of adding an engine.
    assert second.title == "Meet the team &mdash; USAND"
  end

  test "drops a result whose URL is not one, and deduplicates" do
    urls = Brave.parse(body()) |> Enum.map(& &1.url)

    refute "not-a-url" in urls
    assert urls == Enum.uniq(urls)
    assert length(urls) == 3
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
    assert Enum.map(transcript.links, & &1.href) == [
             "https://rewind.com/about/",
             "https://universalsearch.io/meet-the-team",
             "https://www.resilio.com/about/"
           ]

    assert transcript.markdown =~ "[About us | Rewind](https://rewind.com/about/)"
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

    assert result.url == "https://www.resilio.com/about/"
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
    test "absent without a key, present with one" do
      with_key(nil)
      refute Brave.available?()
      refute Brave in Neuron.Search.engines()

      with_key("test-key")
      assert Brave.available?()
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
