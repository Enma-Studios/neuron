defmodule Neuron.Repo.Migrations.AddCachedTokens do
  use Ecto.Migration

  def change do
    alter table(:neuron_usage) do
      add(:cached_tokens, :integer, null: false, default: 0)
    end
  end
end
