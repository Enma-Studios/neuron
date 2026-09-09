defmodule Neuron.Outbox do
  @moduledoc "Publishes local domain intents to Dgraph with retryable delivery."

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enqueue(run_id, kind, payload) do
    id =
      :crypto.hash(:sha256, :erlang.term_to_binary({run_id, kind, payload}))
      |> Base.encode16(case: :lower)

    Neuron.Storage.put_outbox(
      {:neuron_outbox, id, run_id, kind, payload, :pending, 0, DateTime.utc_now()}
    )

    send(__MODULE__, :publish)
    {:ok, id}
  end

  @impl true
  def init(_opts) do
    send(self(), :publish)
    {:ok, %{retry_ms: Application.get_env(:neuron, :storage, [])[:outbox_retry_ms] || 5_000}}
  end

  @impl true
  def handle_info(:publish, state) do
    pending =
      case Neuron.Storage.pending_outbox() do
        {:atomic, entries} -> entries
        _ -> []
      end

    Enum.each(pending, &publish/1)
    Process.send_after(self(), :publish, state.retry_ms)
    {:noreply, state}
  end

  defp publish({:neuron_outbox, id, run_id, kind, payload, :pending, attempts, _updated}) do
    metadata =
      Neuron.Telemetry.trace_metadata(%{
        run_id: run_id,
        operation_id: id,
        task_id: "outbox:publish",
        attempt: attempts + 1
      })

    Neuron.Telemetry.emit(
      [:outbox, :publish],
      Map.merge(metadata, %{kind: kind, payload: Neuron.Telemetry.summarize(payload)})
    )

    facts = graph_facts(kind, id, run_id, payload)

    result =
      Neuron.Graph.upsert(
        facts,
        run_id: run_id,
        operation_id: id,
        task_id: "outbox:publish",
        attempt: attempts + 1
      )

    case result do
      :ok ->
        _ = Neuron.Storage.update_outbox(id, :delivered, attempts + 1, metadata)

      {:error, reason} ->
        Logger.debug("domain publication pending #{id}: #{inspect(reason)}")
        _ = Neuron.Storage.update_outbox(id, :pending, attempts + 1, metadata)
    end
  end

  defp graph_facts(:research_bundle, id, run_id, payload) when is_map(payload) do
    payload
    |> Map.get(:graph, Map.get(payload, "graph"))
    |> case do
      facts when is_map(facts) -> facts
      _ -> generic_facts(id, run_id, payload)
    end
  end

  defp graph_facts(:campaign, id, run_id, payload) when is_map(payload) do
    case Map.get(payload, :graph, Map.get(payload, "graph")) do
      facts when is_map(facts) -> facts
      _ -> generic_facts(id, run_id, payload)
    end
  end

  defp graph_facts(_kind, id, run_id, payload), do: generic_facts(id, run_id, payload)

  defp generic_facts(id, run_id, payload),
    do: %{
      "uid" => "_:#{id}",
      "type" => "outbox",
      "run_id" => run_id,
      "payload" => inspect(payload)
    }
end
