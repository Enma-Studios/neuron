defmodule Neuron.RunRegistry do
  @moduledoc false

  def start_link(_opts), do: Registry.start_link(keys: :unique, name: __MODULE__)

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  def via(id), do: {:via, Registry, {__MODULE__, id}}
end
