defmodule Neuron.Repo.Migrations.CreateCampaignSelections do
  use Ecto.Migration

  def change do
    create table(:neuron_selections, primary_key: false) do
      add(:campaign_id, :string, primary_key: true)
      add(:person_id, :string, primary_key: true)
      add(:run_id, :string, null: false)
      add(:delivered, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:neuron_selections, [:run_id]))
  end
end
