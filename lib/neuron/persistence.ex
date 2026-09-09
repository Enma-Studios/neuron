defmodule Neuron.Persistence do
  @moduledoc "Explicit repository and Oban configuration shared by every durable operation."
  def repo, do: Application.fetch_env!(:neuron, :repo)
  def oban, do: Application.fetch_env!(:neuron, :oban_name)

  def encode(value) do
    validate!(value)
    :erlang.term_to_binary(value)
  end

  defp validate!(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do:
         raise(
           ArgumentError,
           "durable data cannot contain processes, ports, references, or functions"
         )

  defp validate!(value) when is_map(value), do: Enum.each(Map.to_list(value), &validate!/1)

  defp validate!(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.each(&validate!/1)

  defp validate!(value) when is_list(value), do: Enum.each(value, &validate!/1)
  defp validate!(_), do: :ok
  def decode(value), do: :erlang.binary_to_term(value)
end

defmodule Neuron.FSM.Machine do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "neuron_machines" do
    field(:definition, :string)
    field(:state, :string)
    field(:version, :integer, default: 0)
    field(:data, :binary)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Neuron.FSM.Event do
  use Ecto.Schema

  schema "neuron_events" do
    field(:machine_id, :string)
    field(:version, :integer)
    field(:event, :string)
    field(:payload, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Neuron.GraphMigration do
  use Ecto.Schema
  @primary_key {:version, :string, autogenerate: false}
  schema "neuron_graph_migrations" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
