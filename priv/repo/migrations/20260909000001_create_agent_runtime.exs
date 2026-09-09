defmodule Neuron.Repo.Migrations.CreateAgentRuntime do
  use Ecto.Migration
  def up do
    Oban.Migration.up()
    create table(:neuron_machines, primary_key: false) do
      add :id, :string, primary_key: true
      add :definition, :string, null: false
      add :state, :string, null: false
      add :version, :integer, null: false, default: 0
      add :data, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end
    create table(:neuron_events) do
      add :machine_id, :string, null: false
      add :version, :integer, null: false
      add :event, :string, null: false
      add :payload, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create table(:neuron_graph_migrations, primary_key: false) do
      add :version, :string, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:neuron_events, [:machine_id, :id])
  end
  def down do
    drop table(:neuron_graph_migrations)
    drop table(:neuron_events)
    drop table(:neuron_machines)
    Oban.Migration.down()
  end
end
