defmodule Neuron.Test.PostgresRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :neuron, adapter: Ecto.Adapters.Postgres
end
