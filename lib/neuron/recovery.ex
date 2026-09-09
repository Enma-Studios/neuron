defmodule Neuron.Recovery do
  @moduledoc "Re-admits unfinished runs after the local store becomes available."

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :recover)
    {:ok, %{recovered: false}}
  end

  @impl true
  def handle_info(:recover, state) do
    active =
      case Neuron.Storage.list_runs() do
        {:atomic, runs} -> runs
        _ -> []
      end

    Enum.each(active, fn {:neuron_run, id, profile, input, status, _inserted, _updated, _result, _error} ->
      if status in [:queued, :planning, :executing, :waiting] do
        _ = Neuron.RunSupervisor.start_run(id, profile, input, resumed: true)
      end
    end)

    {:noreply, %{state | recovered: true}}
  end
end
