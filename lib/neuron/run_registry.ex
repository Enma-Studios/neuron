defmodule Neuron.RunRegistry do
  @moduledoc false

  def start_link(_opts), do: Registry.start_link(keys: :unique, name: __MODULE__)

  def via(id), do: {:via, Registry, {__MODULE__, id}}
end
