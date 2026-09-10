defmodule Neuron.Browser.Sessions do
  @moduledoc """
  Cleanup owner for provisioned cloud browser sessions.

  A cloud browser is a billed remote resource, so its lifetime must not
  depend on its caller reaching an `after` block. An Oban cancellation, a
  brutal supervisor kill, a linked task exiting, and application shutdown
  all skip `after`, and each of those leaves a browser running until the
  provider's own timeout expires.

  Every provisioned session is registered here against the process that
  opened it. The session is stopped when that owner goes down for any
  reason, when the caller closes it explicitly, or when this process
  terminates with the application.
  """
  use GenServer

  @doc "Register `handle` so it is stopped when `owner` goes down."
  def track(handle, owner \\ self()) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:track, handle, owner})
    end
  end

  @doc "Stop `handle` now and drop its registration."
  def close(handle) do
    case Process.whereis(__MODULE__) do
      nil -> Neuron.Browser.BrowserUse.stop_session(handle)
      _pid -> GenServer.call(__MODULE__, {:close, handle}, :infinity)
    end
  end

  @doc "Sessions currently registered for cleanup."
  def open, do: GenServer.call(__MODULE__, :open)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 30_000}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  # ponytail: stops run serially inside this process. A default fleet holds
  # one session and a wave holds a handful, so the HTTP calls are cheap
  # enough not to need a task per stop; parallelize if fleets grow.
  def handle_call({:track, handle, owner}, _from, sessions) do
    {:reply, :ok, Map.put(sessions, Process.monitor(owner), handle)}
  end

  def handle_call({:close, handle}, _from, sessions) do
    {:reply, stop(handle), drop(sessions, handle)}
  end

  def handle_call(:open, _from, sessions), do: {:reply, Map.values(sessions), sessions}

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, reason}, sessions) do
    case Map.pop(sessions, reference) do
      {nil, sessions} ->
        {:noreply, sessions}

      {handle, sessions} ->
        Neuron.Telemetry.emit(
          [:browser, :session_orphaned],
          %{provider: handle[:provider], reason: inspect(reason)}
        )

        stop(handle)
        {:noreply, sessions}
    end
  end

  def handle_info(_message, sessions), do: {:noreply, sessions}

  @impl true
  def terminate(_reason, sessions) do
    Enum.each(Map.values(sessions), &stop/1)
    :ok
  end

  defp stop(handle) do
    Neuron.Browser.BrowserUse.stop_session(handle)
  catch
    kind, reason ->
      Neuron.Telemetry.emit(
        [:browser, :session_stop_failed],
        %{kind: kind, reason: inspect(reason)}
      )

      :ok
  end

  defp drop(sessions, handle) do
    Enum.reduce(sessions, %{}, fn
      {reference, ^handle}, kept ->
        Process.demonitor(reference, [:flush])
        kept

      {reference, other}, kept ->
        Map.put(kept, reference, other)
    end)
  end
end
