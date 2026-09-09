defmodule Neuron.Repo do
  @moduledoc "Standalone SQLite repository. Hosts may configure their own Ecto repository."
  use Ecto.Repo, otp_app: :neuron, adapter: Ecto.Adapters.SQLite3
end
