defmodule Neuron.SearchTest do
  use ExUnit.Case, async: true

  test "parses DuckDuckGo result links and ignores non-results" do
    html =
      """
      <a class="result__a" href="https://example.com/team">Leadership team</a>
      <a class="other" href="https://example.com/ignored">Ignored</a>
      """

    assert [result] = Neuron.Search.DuckDuckGo.parse(html)
    assert result.url == "https://example.com/team"
    assert result.title == "Leadership team"
  end

  test "parses Google redirect and direct links while dropping Google hosts" do
    html =
      """
      <a href="/url?q=https%3A%2F%2Fexample.com%2Fabout&amp;sa=U">Example About</a>
      <a href="https://www.crunchbase.com/org/acme">Acme on Crunchbase</a>
      <a href="https://accounts.google.com/signin">Sign in</a>
      <a href="https://support.google.com/websearch">Help</a>
      """

    results = Neuron.Search.Google.parse(html)

    assert Enum.map(results, & &1.url) ==
             ["https://example.com/about", "https://www.crunchbase.com/org/acme"]
  end

  test "detects blocked Google traffic" do
    assert Neuron.Search.Google.blocked?("<html>Our systems have detected unusual traffic")
    refute Neuron.Search.Google.blocked?("<html>Results")
  end

  test "parses Yandex organic links and ignores Yandex hosts" do
    html =
      """
      <a class="organic__url" href="https://example.com.ru/team">Команда</a>
      <a class="link" href="https://yandex.com/yandsearch">Search</a>
      <a href="https://wellfound.com/company/acme">Acme</a>
      """

    results = Neuron.Search.Yandex.parse(html)

    assert Enum.map(results, & &1.url) == [
             "https://example.com.ru/team",
             "https://wellfound.com/company/acme"
           ]
  end

  test "parses LinkedIn profile and company links from native search" do
    html =
      """
      <a href="https://www.linkedin.com/in/acme-founder?trackingId=xyz">Jane Founder — CTO</a>
      <a href="/company/acme">Acme</a>
      <a href="https://www.linkedin.com/feed/">Home</a>
      """

    results = Neuron.Search.LinkedIn.parse(html)

    assert Enum.map(results, & &1.url) == [
             "https://www.linkedin.com/in/acme-founder",
             "https://www.linkedin.com/company/acme"
           ]
  end

  test "detects gated LinkedIn pages and strips site operators" do
    assert Neuron.Search.LinkedIn.gated?("<html>authwall</html>")
    refute Neuron.Search.LinkedIn.gated?("<html>results</html>")

    assert Neuron.Search.LinkedIn.keywords("site:linkedin.com fintech founder Berlin") ==
             "fintech founder Berlin"
  end

  test "parses X handles while ignoring navigation paths" do
    html =
      """
      <a href="/janefounder" data-testid="UserLink"><span>Jane</span><span>@janefounder</span></a>
      <a href="/home">Home</a>
      <a href="/notifications">Notifications</a>
      """

    assert [result] = Neuron.Search.X.parse(html)
    assert result.url == "https://x.com/janefounder"
    assert result.title == "Jane @janefounder"
  end

  test "parses Reddit search result titles" do
    html =
      """
      <a class="search-title may-blank" href="https://www.reddit.com/r/startups/comments/1/acme">Looking for feedback on Acme</a>
      <a class="search-comments may-blank" href="https://www.reddit.com/r/startups/1/acme">42 comments</a>
      """

    assert [result] = Neuron.Search.Reddit.parse(html)
    assert result.url == "https://www.reddit.com/r/startups/comments/1/acme"
    assert result.title == "Looking for feedback on Acme"
  end

  test "every engine exposes the shared behaviour surface" do
    for engine <- [
          Neuron.Search.DuckDuckGo,
          Neuron.Search.Google,
          Neuron.Search.Yandex,
          Neuron.Search.LinkedIn,
          Neuron.Search.X,
          Neuron.Search.Reddit
        ] do
      assert engine.kind() in [:web, :social]
      assert String.starts_with?(engine.search_url("acme founder"), "https://")
      assert is_list(engine.parse("<html></html>"))
      assert is_boolean(engine.blocked?("<html></html>"))
      assert is_boolean(engine.gated?("<html></html>"))
    end
  end

  describe "web/2 engine fan-out" do
    test "merges corroborated results across engines with attribution" do
      results =
        Neuron.Search.web("acme founder",
          engines: [Neuron.SearchTest.WebEngine, Neuron.SearchTest.SocialEngine],
          handles: [%{provider: :fake, session: nil}],
          pages_per_session: 2,
          page_adapter: Neuron.SearchTest.PageAdapter
        )

      assert {:ok, merged} = results
      assert length(merged) == 3
      [top | _rest] = merged
      assert top.url == "https://shared.example/founder"

      assert MapSet.new(top.engines) ==
               MapSet.new([Neuron.SearchTest.WebEngine, Neuron.SearchTest.SocialEngine])
    end

    test "skips social engines when only site operators remain" do
      assert {:ok, []} =
               Neuron.Search.web("site:linkedin.com",
                 engines: [Neuron.SearchTest.SocialEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )
    end

    test "treats gated engines as failures without failing the search" do
      test_pid = self()
      handler = "engine-failed-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler,
        [[:neuron, :search, :engine_failed]],
        fn event, _measurements, meta, _ ->
          send(test_pid, {event, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, merged} =
               Neuron.Search.web("acme founder",
                 engines: [Neuron.SearchTest.WebEngine, Neuron.SearchTest.GatedEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert Enum.all?(merged, &(&1.url != "https://gated.example/never"))

      assert_receive {[:neuron, :search, :engine_failed],
                      %{engine: "Neuron.SearchTest.GatedEngine"}}
    end

    test "falls back to a single provider when every engine fails" do
      assert {:ok, [result]} =
               Neuron.Search.web("acme founder",
                 engines: [Neuron.SearchTest.GatedEngine],
                 fallback_provider: Neuron.SearchTest.FallbackEngine,
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert result.url == "https://fallback.example/result"
    end
  end

  describe "platform-tailored planning" do
    test "maps planned platform ids to engines, dropping unknowns and duplicates" do
      assert {:ok, searches} =
               Neuron.Search.plan_searches("acme decision makers",
                 engines: [Neuron.SearchTest.WebEngine, Neuron.SearchTest.SocialEngine],
                 model_provider: Neuron.SearchTest.PlanningModel
               )

      assert searches == [
               %{engine: Neuron.SearchTest.WebEngine, query: "acme CTO email"},
               %{engine: Neuron.SearchTest.SocialEngine, query: "acme founder"}
             ]
    end

    test "web/2 runs supplied searches without consulting the planner" do
      assert {:ok, merged} =
               Neuron.Search.web("ignored by planner",
                 searches: [%{engine: Neuron.SearchTest.WebEngine, query: "q"}],
                 engines: [Neuron.SearchTest.WebEngine],
                 model_provider: Neuron.SearchTest.RaisingModel,
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert MapSet.new(Enum.map(merged, & &1.url)) ==
               MapSet.new(["https://web.example/only", "https://shared.example/founder"])
    end

    test "web/2 degrades to raw engine queries when planning fails" do
      assert {:ok, merged} =
               Neuron.Search.web("acme founder",
                 engines: [Neuron.SearchTest.WebEngine],
                 model_provider: Neuron.SearchTest.FailingModel,
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert MapSet.new(Enum.map(merged, & &1.url)) ==
               MapSet.new(["https://web.example/only", "https://shared.example/founder"])
    end
  end

  describe "orchestration" do
    test "runs searches as transcript pages and harvests them with the model" do
      searches = [
        %{engine: Neuron.SearchTest.SocialEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.LoginEngine, query: "acme CTO"}
      ]

      assert {:ok, merged, failures} =
               Neuron.Search.orchestrate(searches,
                 engines: [Neuron.SearchTest.SocialEngine, Neuron.SearchTest.LoginEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.TranscriptAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel,
                 fixture_domain: "buyer.example"
               )

      assert [%{url: "https://buyer.example/team", engines: [Neuron.SearchTest.SocialEngine]}] =
               merged

      assert [%{engine: Neuron.SearchTest.LoginEngine, query: "acme CTO", reason: reason}] =
               failures

      assert reason =~ "login gate"
    end

    test "errors only when every search fails" do
      assert {:error, {:search_unavailable, reason: {:all_searches_failed, _}}} =
               Neuron.Search.orchestrate([%{engine: Neuron.SearchTest.LoginEngine, query: "q"}],
                 engines: [Neuron.SearchTest.LoginEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.TranscriptAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel
               )
    end
  end
end
