defmodule Neuron.Migrations do
  @moduledoc """
  Version registry for durable Neuron migrations.

  Add a new entry when a migration changes storage or the graph schema. Entries
  are append-only so deployed nodes can apply each version exactly once.
  """

  @mnesia [{1, "create_core_tables"}]

  def versions(:mnesia), do: @mnesia
  def versions(:dgraph), do: [{Neuron.Graph.Schema.version(), "graph_schema"}]

  def pending(backend, applied_versions) do
    Enum.reject(versions(backend), fn {version, _name} -> version in applied_versions end)
  end
end
