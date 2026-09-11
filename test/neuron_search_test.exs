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

  test "unwraps engine redirect links into the page they point at" do
    assert Neuron.Search.Engine.unwrap(
             "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fblog.helpdocs.io%2Frebuilding%2D&rut=abc"
           ) == "https://blog.helpdocs.io/rebuilding-"

    assert Neuron.Search.Engine.unwrap(
             "https://www.google.com/url?q=https%3A%2F%2Facme.example%2Fteam&sa=U"
           ) ==
             "https://acme.example/team"

    # Anything that is not a known wrapper is left exactly as it was.
    assert Neuron.Search.Engine.unwrap("https://acme.example/team") == "https://acme.example/team"

    assert Neuron.Search.Engine.unwrap("https://duckduckgo.com/settings") ==
             "https://duckduckgo.com/settings"
  end

  describe "wall_reason/1" do
    test "reports a login gate, a bot wall, and a clean page" do
      assert {:login_gate, reason} =
               Neuron.Search.wall_reason(%{
                 url: "https://www.linkedin.com/authwall?sessionRedirect=x",
                 document: "",
                 engine: Neuron.SearchTest.WebEngine
               })

      assert reason =~ "login gate"

      assert {:consent_wall, _} =
               Neuron.Search.wall_reason(%{
                 url: "https://www.google.com/sorry/index?continue=x",
                 document: "",
                 engine: Neuron.SearchTest.WebEngine
               })

      assert Neuron.Search.wall_reason(%{
               url: "https://web.example/search?q=acme",
               document: "<html>results</html>",
               engine: Neuron.SearchTest.WebEngine
             }) == nil
    end

    test "reads the engine's own bot check markers off the returned document" do
      assert {:bot_check, reason} =
               Neuron.Search.wall_reason(%{
                 url: "https://www.google.com/search?q=acme",
                 document: "<html>Our systems have detected unusual traffic</html>",
                 engine: Neuron.Search.Google
               })

      assert reason =~ "bot check"
    end
  end

  describe "balance/2" do
    test "gives every enabled engine a query without growing the round" do
      planned = [
        %{engine: Neuron.SearchTest.WebEngine, query: "one"},
        %{engine: Neuron.SearchTest.WebEngine, query: "two"},
        %{engine: Neuron.SearchTest.WebEngine, query: "three"}
      ]

      balanced =
        Neuron.Search.balance(planned, [
          Neuron.SearchTest.WebEngine,
          Neuron.SearchTest.SocialEngine
        ])

      assert length(balanced) == length(planned)
      assert Enum.map(balanced, & &1.query) == ["one", "two", "three"]

      assert Enum.frequencies_by(balanced, & &1.engine) == %{
               Neuron.SearchTest.WebEngine => 2,
               Neuron.SearchTest.SocialEngine => 1
             }
    end

    test "leaves a round that already covers every engine alone" do
      planned = [
        %{engine: Neuron.SearchTest.WebEngine, query: "one"},
        %{engine: Neuron.SearchTest.SocialEngine, query: "two"}
      ]

      assert Neuron.Search.balance(planned, [
               Neuron.SearchTest.WebEngine,
               Neuron.SearchTest.SocialEngine
             ]) == planned
    end

    test "never strips an engine bare to cover another" do
      # One query, two engines: covering the second would uncover the first,
      # so the round stays as planned rather than trading one gap for another.
      planned = [%{engine: Neuron.SearchTest.WebEngine, query: "one"}]

      assert Neuron.Search.balance(planned, [
               Neuron.SearchTest.WebEngine,
               Neuron.SearchTest.SocialEngine
             ]) == planned
    end
  end

  describe "the default engine set" do
    test "is DuckDuckGo and Yandex, and no engine that needs a login or fails a bot check" do
      # The application default and the compiled fallback must agree, or the
      # engine set depends on whether config was loaded.
      configured = Application.get_env(:neuron, :search, [])[:engines]

      assert Neuron.Search.engines() == [Neuron.Search.DuckDuckGo, Neuron.Search.Yandex]
      assert configured == [Neuron.Search.DuckDuckGo, Neuron.Search.Yandex]
    end

    test "never contains a walled or logged-in engine" do
      # An edit that puts one of these back must fail here rather than in a
      # billed run: LinkedIn and X need a logged-in profile, Reddit redirects
      # cloud addresses to a login wall, and Google bot-checks every query.
      for engine <- [
            Neuron.Search.LinkedIn,
            Neuron.Search.X,
            Neuron.Search.Reddit,
            Neuron.Search.Google
          ] do
        refute engine in Neuron.Search.engines(),
               "#{inspect(engine)} must not be enabled by default"
      end
    end

    test "an engine switched off by default is still supported when asked for" do
      assert Neuron.Search.engines(engines: [Neuron.Search.Google]) == [Neuron.Search.Google]
    end
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
          searches: [
            %{engine: Neuron.SearchTest.WebEngine, query: "acme founder"},
            %{engine: Neuron.SearchTest.SocialEngine, query: "acme founder"}
          ],
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
                 searches: [%{engine: Neuron.SearchTest.SocialEngine, query: "site:linkedin.com"}],
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
                 searches: [
                   %{engine: Neuron.SearchTest.WebEngine, query: "acme founder"},
                   %{engine: Neuron.SearchTest.GatedEngine, query: "acme founder"}
                 ],
                 engines: [Neuron.SearchTest.WebEngine, Neuron.SearchTest.GatedEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert Enum.all?(merged, &(&1.url != "https://gated.example/never"))

      assert_receive {[:neuron, :search, :engine_failed],
                      %{engine: "Neuron.SearchTest.GatedEngine"}}
    end

    test "fails the search when every engine fails" do
      assert {:error, {:search_unavailable, reason: {:engines_exhausted, failures}}} =
               Neuron.Search.web("acme founder",
                 searches: [%{engine: Neuron.SearchTest.GatedEngine, query: "acme founder"}],
                 engines: [Neuron.SearchTest.GatedEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )

      assert [{Neuron.SearchTest.GatedEngine, {:engine_gated, Neuron.SearchTest.GatedEngine}}] =
               failures
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

    test "web/2 propagates planning failures instead of degrading" do
      assert {:error, :planner_down} =
               Neuron.Search.web("acme founder",
                 engines: [Neuron.SearchTest.WebEngine],
                 model_provider: Neuron.SearchTest.FailingModel,
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.PageAdapter
               )
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

    test "two engines, one bot-checked, and the round succeeds on the other" do
      # The shape that failed four of ten live runs: the planner put every
      # query of the round on one engine and that engine was walled.
      planned = [
        %{engine: Neuron.SearchTest.WalledEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.WalledEngine, query: "acme founder email"}
      ]

      enabled = [Neuron.SearchTest.WalledEngine, Neuron.SearchTest.SocialEngine]

      assert {:ok, merged, failures} =
               Neuron.Search.orchestrate(Neuron.Search.balance(planned, enabled),
                 engines: enabled,
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.MixedAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel,
                 fixture_domain: "buyer.example"
               )

      assert [%{url: "https://buyer.example/team"}] = merged
      assert [%{engine: Neuron.SearchTest.WalledEngine, kind: :bot_check}] = failures
    end

    test "an enabled engine nobody asked is not evidence that search is unavailable" do
      # Every attempted engine failed, but Yandex's stand-in was never tried,
      # so the round is degraded rather than unavailable.
      assert {:ok, [], failures} =
               Neuron.Search.orchestrate(
                 [%{engine: Neuron.SearchTest.WalledEngine, query: "acme CTO"}],
                 engines: [Neuron.SearchTest.WalledEngine, Neuron.SearchTest.SocialEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.MixedAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel
               )

      assert [%{engine: Neuron.SearchTest.WalledEngine, kind: :bot_check}] = failures
    end

    test "a login gate on one engine leaves the other two to carry the round" do
      searches = [
        %{engine: Neuron.SearchTest.WebEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.SocialEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.LoginEngine, query: "acme CTO"}
      ]

      assert {:ok, merged, failures} =
               Neuron.Search.orchestrate(searches,
                 engines: [
                   Neuron.SearchTest.WebEngine,
                   Neuron.SearchTest.SocialEngine,
                   Neuron.SearchTest.LoginEngine
                 ],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 3,
                 page_adapter: Neuron.SearchTest.MixedAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel,
                 fixture_domain: "buyer.example"
               )

      # The round succeeded, and both engines that answered are credited.
      assert [%{url: "https://buyer.example/team", engines: engines}] = merged

      assert MapSet.new(engines) ==
               MapSet.new([Neuron.SearchTest.WebEngine, Neuron.SearchTest.SocialEngine])

      # The gated engine is a skipped engine, named, with its kind.
      assert [%{engine: Neuron.SearchTest.LoginEngine, kind: :login_gate, reason: reason}] =
               failures

      assert reason =~ "login gate"
    end

    test "a walled engine is skipped and the engines that answered carry the round" do
      searches = [
        %{engine: Neuron.SearchTest.SocialEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.WalledEngine, query: "acme CTO"},
        %{engine: Neuron.SearchTest.LoginEngine, query: "acme CTO"}
      ]

      assert {:ok, merged, failures} =
               Neuron.Search.orchestrate(searches,
                 engines: [
                   Neuron.SearchTest.SocialEngine,
                   Neuron.SearchTest.WalledEngine,
                   Neuron.SearchTest.LoginEngine
                 ],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 3,
                 page_adapter: Neuron.SearchTest.MixedAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel,
                 fixture_domain: "buyer.example"
               )

      assert [%{url: "https://buyer.example/team"}] = merged

      reasons = Map.new(failures, &{&1.engine, &1.reason})
      assert reasons[Neuron.SearchTest.WalledEngine] =~ "bot check"
      assert reasons[Neuron.SearchTest.LoginEngine] =~ "login gate"
    end

    test "errors only when every engine failed, and names each one" do
      searches = [
        %{engine: Neuron.SearchTest.LoginEngine, query: "q"},
        %{engine: Neuron.SearchTest.WalledEngine, query: "q"}
      ]

      assert {:error, {:search_unavailable, reason: {:all_searches_failed, failures}}} =
               Neuron.Search.orchestrate(searches,
                 engines: [Neuron.SearchTest.LoginEngine, Neuron.SearchTest.WalledEngine],
                 handles: [%{provider: :fake, session: nil}],
                 pages_per_session: 2,
                 page_adapter: Neuron.SearchTest.MixedAgent,
                 model_provider: Neuron.SearchTest.TeamHarvestModel
               )

      assert Map.new(failures, &{&1.engine, &1.kind}) == %{
               Neuron.SearchTest.LoginEngine => :login_gate,
               Neuron.SearchTest.WalledEngine => :bot_check
             }
    end
  end
end
