defmodule Neuron.Application do
  @moduledoc "Standalone or host-managed repository, Oban, and pipeline supervision."
  use Application

  def start(_type, _args) do
    repo = Neuron.Persistence.repo()
    repo_children = if Application.fetch_env!(:neuron, :start_repo), do: [repo], else: []

    oban_children =
      if Application.fetch_env!(:neuron, :start_oban) do
        opts =
          Application.fetch_env!(:neuron, :oban)
          |> Keyword.merge(repo: repo, name: Neuron.Persistence.oban())

        [{Oban, opts}]
      else
        []
      end

    Supervisor.start_link(
      repo_children ++
        oban_children ++
        Neuron.Embedding.children() ++
        [
          {Neuron.Dgraph, []},
          {Neuron.Browser.Sessions, []},
          {DynamicSupervisor, name: Neuron.PipelineSupervisor, strategy: :one_for_one}
        ],
      strategy: :one_for_one,
      name: Neuron.Supervisor
    )
  end
end
