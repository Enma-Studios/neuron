defmodule Neuron.Browser.NavigateTest do
  use ExUnit.Case, async: false

  alias Neuron.Browser.BrowserUse

  setup do
    browser = Application.get_env(:neuron, :browser, [])
    on_exit(fn -> Application.put_env(:neuron, :browser, browser) end)
    :ok
  end

  test "the navigation budget is the caller's, then the fleet's, then a minute" do
    Application.put_env(:neuron, :browser, fleet: [timeout: 120_000])

    # `Pinocchio.Browser.visit_and_wait/3` discarded this entirely: its
    # `expect_navigation/2` ignores options and its `await/1` hardcodes 30
    # seconds, so a page allowed 120 was cut off at 30.
    assert BrowserUse.timeout(timeout: 5_000) == 5_000
    assert BrowserUse.timeout([]) == 120_000

    Application.put_env(:neuron, :browser, [])
    assert BrowserUse.timeout([]) == 60_000
  end

  describe "a page that never settles" do
    defmodule NeverSettles do
      # Every probe reports a different size, so the page never settles.
      def execute_script(_page, _script),
        do: {:ok, %{"result" => %{"value" => System.unique_integer([:positive])}}}

      def current_url(_page), do: "https://acme.example/slow"
    end

    test "is a tagged error, not an exit, and honours the timeout it was given" do
      # The defect was that the wait exited rather than returning. An exit is
      # not an exception, so no `with` catches it and no `rescue` sees it, and
      # it killed the caller instead of failing the fetch.
      {elapsed, result} =
        :timer.tc(fn ->
          Neuron.Browser.Fleet.CDP.wait_ready(:page, nil, 400, NeverSettles)
        end)

      assert result == {:error, :page_not_ready}
      assert elapsed < 3_000_000
    end
  end

  test "a settled page is ready, and a redirect elsewhere is still accepted" do
    # A direct fetch passes nil for the URL, because it accepts wherever a
    # redirect landed and reads the final URL off the page.
    assert Neuron.Browser.Fleet.CDP.wait_ready(:page, nil, 2_000, Neuron.BrowserTest.SettledPage) ==
             :ok
  end

  test "a fleet tab still has to be reading its own page" do
    # With a host expected, settling is not enough: a tab must confirm it is
    # not reading a sibling tab's document.
    assert Neuron.Browser.Fleet.CDP.wait_ready(
             :page,
             "https://acme.example/team",
             2_000,
             Neuron.BrowserTest.SettledPage
           ) == :ok

    assert Neuron.Browser.Fleet.CDP.wait_ready(
             :page,
             "https://elsewhere.example/team",
             400,
             Neuron.BrowserTest.SettledPage
           ) == {:error, :page_not_ready}
  end

  @tag :integration
  test "the repro's sequence completes with a profile" do
    key = System.get_env("BROWSER_USE_API_KEY")
    profile = System.get_env("BROWSER_USE_PROFILE_ID")

    if is_nil(key) or key == "" or is_nil(profile) or profile == "" do
      flunk("BROWSER_USE_API_KEY and BROWSER_USE_PROFILE_ID must both be set for this test")
    end

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:pinocchio)
    url = System.get_env("REPRO_URL", "https://rewind.com/about/")

    # Three navigations on one session: the shape that exited on a hardcoded
    # 30 second GenServer.call and killed its caller.
    {:ok, handle} = Neuron.Browser.BrowserUse.open_session([])

    try do
      for attempt <- 1..3 do
        assert :ok = Neuron.Browser.BrowserUse.navigate(handle.session, url, 60_000),
               "navigation #{attempt} of 3 did not complete"
      end
    after
      Neuron.Browser.BrowserUse.close_session(handle)
    end

    # And three separate fetches, the shape three intake planning passes make.
    for attempt <- 1..3 do
      assert {:ok, page} = Neuron.Browser.fetch(url, timeout: 60_000),
             "fetch #{attempt} of 3 did not complete"

      assert byte_size(page[:html] || "") > 0
    end
  end
end
