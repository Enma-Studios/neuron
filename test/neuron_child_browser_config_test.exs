defmodule Neuron.ChildBrowserConfigTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Neuron.Browser.BrowserUse

  setup do
    browser = Application.get_env(:neuron, :browser, [])
    env = System.get_env("BROWSER_USE_API_KEY")

    on_exit(fn ->
      Application.put_env(:neuron, :browser, browser)

      if env,
        do: System.put_env("BROWSER_USE_API_KEY", env),
        else: System.delete_env("BROWSER_USE_API_KEY")
    end)

    System.delete_env("BROWSER_USE_API_KEY")
    :ok
  end

  defp configure(browser_use) do
    Application.put_env(
      :neuron,
      :browser,
      Keyword.put(Application.get_env(:neuron, :browser, []), :browser_use, browser_use)
    )
  end

  test "a child started under a configured parent can open a session" do
    configure(api_key: "parent-key")

    # The options a campaign's dispatch stage hands a child: the parent's run
    # options, plus the child's identity.
    parent_opts = [
      trace_id: Ecto.UUID.generate(),
      organization_id: "acme",
      campaign_id: Ecto.UUID.generate()
    ]

    child_id = Ecto.UUID.generate()

    child_opts =
      parent_opts
      |> Keyword.put(:id, child_id)
      |> Keyword.put(:parent_run_id, Ecto.UUID.generate())

    {:ok, ^child_id} = Neuron.Ingestion.submit(%{url: "https://acme.example/team"}, child_opts)

    # What the child's stage worker will run with, rebuilt the way it does.
    stage_opts =
      child_id
      |> Neuron.FSM.get()
      |> Neuron.FSM.data()
      |> Map.fetch!(:opts)
      |> Keyword.put(:run_id, child_id)
      |> Keyword.put(:stage, :fetch)

    # The parent's options reached the child intact.
    assert stage_opts[:organization_id] == "acme"
    assert stage_opts[:trace_id] == parent_opts[:trace_id]

    # And the child can open a session: it gets past the configuration check
    # rather than reporting :browser_use_not_configured.
    assert BrowserUse.configured?()
    assert BrowserUse.api_key() == "parent-key"
    refute match?({:error, :browser_use_not_configured}, BrowserUse.open_session(stage_opts))
  end

  test "a host's partial browser block does not wipe the browser_use key" do
    # Elixir configuration replaces a keyword rather than merging into it, so
    # a host writing only `fleet:` used to leave browser_use empty and every
    # browser call depending on an ambient environment variable.
    configure(api_key: "host-key")
    assert BrowserUse.api_key() == "host-key"

    Application.put_env(:neuron, :browser, fleet: [sessions: 2])
    refute BrowserUse.configured?()

    # The defaults survive a partial block rather than vanishing with it.
    assert BrowserUse.session_ttl_seconds() == 3600
  end

  test "the environment is the fallback, and configuration wins over it" do
    configure([])
    System.put_env("BROWSER_USE_API_KEY", "from-the-environment")
    assert BrowserUse.api_key() == "from-the-environment"

    configure(api_key: "from-configuration")
    assert BrowserUse.api_key() == "from-configuration"
  end

  test "an empty key is not a key" do
    configure(api_key: "")
    refute BrowserUse.configured?()

    System.put_env("BROWSER_USE_API_KEY", "")
    refute BrowserUse.configured?()
  end

  describe "a batch of children that could not browse" do
    defp child(status, error) do
      {:ok, machine} =
        Neuron.FSM.create(
          Neuron.Run,
          %{profile: Neuron.Ingestion, input: %{}, opts: [], result: %{}, error: error},
          id: Ecto.UUID.generate()
        )

      if status != "planning" do
        Neuron.Persistence.repo().update_all(
          from(m in Neuron.FSM.Machine, where: m.id == ^machine.id),
          set: [state: status]
        )
      end

      %{id: machine.id, source: %{url: "https://acme.example/#{machine.id}"}}
    end

    defp collect(children) do
      Neuron.CampaignPipeline.stage(
        :collect,
        %{pending_children: children, failures: [], leads: []},
        []
      )
    end

    test "fails the run rather than reporting that it found nothing" do
      children = for _ <- 1..4, do: child("failed", :browser_use_not_configured)

      assert {:error, :browser_use_not_configured} = collect(children)
    end

    test "a batch that only partly failed carries on, with the cause recorded" do
      children = [
        child("complete", nil) | for(_ <- 1..3, do: child("failed", :browser_use_not_configured))
      ]

      assert {:ok, data} = collect(children)
      assert length(data.failures) == 3
      assert Enum.all?(data.failures, &(&1.kind == :browser))
    end

    test "children that failed for other reasons are recorded, not reinterpreted" do
      children = for _ <- 1..2, do: child("failed", {:zai_transport, :timeout})

      assert {:ok, data} = collect(children)
      assert Enum.all?(data.failures, &(&1.kind == :model))
    end
  end

  test "an unconfigured browser says where it looked instead of failing silently" do
    configure([])

    handler = "not-configured-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      [:neuron, :browser, :not_configured],
      fn _e, _m, meta, _ ->
        send(test, {:not_configured, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :browser_use_not_configured} =
             BrowserUse.fetch("https://acme.example", run_id: "r1")

    assert_receive {:not_configured, meta}
    assert meta.checked =~ "BROWSER_USE_API_KEY"
    assert meta.run_id == "r1"
  end
end
