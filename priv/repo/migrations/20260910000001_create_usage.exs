defmodule Neuron.Repo.Migrations.CreateUsage do
  use Ecto.Migration

  def change do
    create table(:neuron_usage) do
      add(:run_id, :string, null: false)
      add(:parent_run_id, :string)
      add(:stage, :string)
      add(:kind, :string, null: false)
      add(:label, :string)
      add(:prompt_tokens, :integer, null: false, default: 0)
      add(:completion_tokens, :integer, null: false, default: 0)
      add(:seconds, :float, null: false, default: 0.0)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:neuron_usage, [:run_id]))
    create(index(:neuron_usage, [:parent_run_id]))
  end
end
