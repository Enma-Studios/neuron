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

  # A remote stop is an HTTP call with a 15 second receive timeout; a close
  # that waits longer than this gives up waiting, and the stop carries on.
  @close_timeout 30_000

  @doc "Register `handle` so it is stopped when `owner` goes down."
  def track(handle, owner \\ self()) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:track, handle, owner})
    end
  end

  @doc """
  Stop `handle` now and drop its registration. Returns once the remote stop
  has finished, or after #{div(@close_timeout, 1000)} seconds, whichever
  comes first.
  """
  def close(handle) do
    case Process.whereis(__MODULE__) do
      nil ->
        Neuron.Browser.BrowserUse.stop_session(handle)

      _pid ->
        try do
          GenServer.call(__MODULE__, {:close, handle}, @close_timeout)
        catch
          :exit, reason ->
            Neuron.Telemetry.emit(
              [:browser, :session_close_timeout],
              %{provider: handle[:provider], reason: inspect(reason)}
            )

            :ok
        end
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
    {:ok, %{sessions: %{}, stopping: %{}}}
  end

  # This process owns the registry only. Every remote stop runs in its own
  # task: run inline, one slow stop blocked every other close behind it, and
  # every track behind those timed out (#38).
  @impl true
  def handle_call({:track, handle, owner}, _from, state) do
    {:reply, :ok, put_in(state.sessions[Process.monitor(owner)], handle)}
  end

  def handle_call({:close, handle}, from, state) do
    {:noreply, state |> Map.update!(:sessions, &drop(&1, handle)) |> start_stop(handle, from)}
  end

  def handle_call(:open, _from, state), do: {:reply, Map.values(state.sessions), state}

  @impl true
  def handle_info({reference, result}, state) when is_map_key(state.stopping, reference) do
    Process.demonitor(reference, [:flush])
    {{_task, from}, stopping} = Map.pop(state.stopping, reference)
    if from, do: GenServer.reply(from, result)
    {:noreply, %{state | stopping: stopping}}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state)
      when is_map_key(state.stopping, reference) do
    {{_task, from}, stopping} = Map.pop(state.stopping, reference)
    if from, do: GenServer.reply(from, :ok)
    {:noreply, %{state | stopping: stopping}}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.sessions, reference) do
      {nil, _sessions} ->
        {:noreply, state}

      {handle, sessions} ->
        Neuron.Telemetry.emit(
          [:browser, :session_orphaned],
          %{provider: handle[:provider], reason: inspect(reason)}
        )

        {:noreply, start_stop(%{state | sessions: sessions}, handle, nil)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Shutdown stops what is still registered and waits for every stop in
  # flight, within the child's shutdown budget.
  @impl true
  def terminate(_reason, state) do
    remaining =
      Enum.map(Map.values(state.sessions), fn handle -> Task.async(fn -> stop(handle) end) end)

    in_flight = Enum.map(Map.values(state.stopping), fn {task, _from} -> task end)
    Task.yield_many(remaining ++ in_flight, 25_000)
    :ok
  end

  defp start_stop(state, handle, from) do
    task = Task.async(fn -> stop(handle) end)
    put_in(state.stopping[task.ref], {task, from})
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
