defmodule Neuron.Storage do
  @moduledoc "SQL event history for prompts, tool calls, handovers, and run decisions."
  import Ecto.Query
  alias Neuron.Persistence, as: P
  alias Neuron.FSM.Event

  def next_event(id, type, payload, metadata \\ %{}) do
    P.repo().insert!(%Event{
      machine_id: id,
      version: 0,
      event: to_string(type),
      payload: P.encode(%{data: payload, metadata: metadata})
    })
  end

  def events(id) do
    P.repo().all(from(e in Event, where: e.machine_id == ^id, order_by: e.id))
    |> Enum.map(fn e ->
      %{
        id: e.id,
        event: e.event,
        version: e.version,
        payload: P.decode(e.payload),
        inserted_at: e.inserted_at
      }
    end)
  end
end
