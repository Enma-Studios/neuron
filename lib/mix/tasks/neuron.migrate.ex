defmodule Mix.Tasks.Neuron.Migrate do
  use Mix.Task
  @shortdoc "Apply versioned SQL runtime and Oban migrations"
  def run([]) do
    Mix.Task.run("app.config")
    repo = Neuron.Persistence.repo()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, Application.app_dir(:neuron, "priv/repo/migrations"), :up,
          all: true
        )
      end)
  end
end
