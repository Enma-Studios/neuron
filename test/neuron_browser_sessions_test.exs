defmodule Neuron.Browser.SessionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Built by the test process so the recorded stop is delivered here rather
  # than to the owner the test is about to kill.
  defp handle(id, reply_to) do
    %{
      pid: nil,
      provider: :browser_use,
      stop_with: Neuron.BrowserTest.RecordingProvider,
      prepared: %{provider_session: %{id: id, reply_to: reply_to}}
    }
  end

  setup do
    on_exit(fn ->
      for open <- Neuron.Browser.Sessions.open(), do: Neuron.Browser.Sessions.close(open)
    end)

    :ok
  end

  test "a task that raises still leaves zero open sessions" do
    owner = self()
    first = handle("raising-1", owner)
    second = handle("raising-2", owner)

    capture_log(fn ->
      {:ok, _pid} =
        Task.start(fn ->
          :ok = Neuron.Browser.Sessions.track(first)
          :ok = Neuron.Browser.Sessions.track(second)
          send(owner, :tracked)
          raise "stage blew up"
        end)

      assert_receive :tracked, 1_000
      assert_receive {:stopped, "raising-1"}, 2_000
      assert_receive {:stopped, "raising-2"}, 2_000
    end)

    assert Neuron.Browser.Sessions.open() == []
  end

  test "a killed owner stops its session" do
    owner = self()
    tracked = handle("killed", owner)

    pid =
      spawn(fn ->
        :ok = Neuron.Browser.Sessions.track(tracked)
        send(owner, :tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :tracked, 1_000
    Process.exit(pid, :kill)

    assert_receive {:stopped, "killed"}, 2_000
    assert Neuron.Browser.Sessions.open() == []
  end

  test "an explicit close stops the session once and drops its registration" do
    tracked = handle("explicit", self())
    :ok = Neuron.Browser.Sessions.track(tracked)
    assert Neuron.Browser.Sessions.open() == [tracked]

    assert :ok = Neuron.Browser.Sessions.close(tracked)
    assert_receive {:stopped, "explicit"}, 1_000
    assert Neuron.Browser.Sessions.open() == []

    # The owner outliving its closed session must not stop it a second time.
    refute_receive {:stopped, "explicit"}, 200
  end

  test "sweep stops only sessions still running past the TTL" do
    now = ~U[2026-09-10 12:00:00Z]

    listing = [
      %{
        "id" => "stale-open",
        "status" => "running",
        "finishedAt" => nil,
        "startedAt" => "2026-09-10T10:00:00Z"
      },
      %{
        "id" => "fresh-open",
        "status" => "running",
        "finishedAt" => nil,
        "startedAt" => "2026-09-10T11:59:00Z"
      },
      %{
        "id" => "old-stopped",
        "status" => "stopped",
        "finishedAt" => "2026-09-10T10:05:00Z",
        "startedAt" => "2026-09-10T10:00:00Z"
      }
    ]

    assert ["stale-open"] = Neuron.Browser.BrowserUse.stale_sessions(listing, now, 3600)
  end
end
