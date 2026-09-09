defmodule Neuron.Persistence do
  @moduledoc "Explicit repository and Oban configuration shared by every durable operation."
  def repo, do: Application.fetch_env!(:neuron, :repo)
  def oban, do: Application.fetch_env!(:neuron, :oban_name)
  def encode(value), do: :erlang.term_to_binary(value)
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
