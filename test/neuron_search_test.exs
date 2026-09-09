defmodule Neuron.SearchTest do
  use ExUnit.Case, async: true

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
end
