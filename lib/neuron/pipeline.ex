defmodule Neuron.Pipeline do
  @moduledoc "Bounded GenStage processing supervised for the lifetime of an Oban stage."
  def map([], _fun, _opts), do: []

  def map(items, fun, opts) do
    concurrency = Keyword.fetch!(opts, :max_concurrency)
    true = is_integer(concurrency) and concurrency > 0

    {:ok, supervisor} =
      DynamicSupervisor.start_child(
        Neuron.PipelineSupervisor,
        Supervisor.child_spec({Neuron.Pipeline.Supervisor, owner: self()}, restart: :temporary)
      )

    try do
      {:ok, producer} =
        Supervisor.start_child(
          supervisor,
          %{
            id: :source,
            start: {Neuron.Pipeline.Source, :start_link, [items]},
            restart: :temporary
          }
        )

      workers =
        for index <- 1..min(concurrency, length(items)) do
          {:ok, worker} =
            Supervisor.start_child(
              supervisor,
              %{
                id: index,
                start: {Neuron.Pipeline.Mapper, :start_link, [{producer, fun}]},
                restart: :temporary
              }
            )

          {worker, max_demand: 1, min_demand: 0}
        end

      workers |> GenStage.stream() |> Enum.take(length(items))
    after
      DynamicSupervisor.terminate_child(Neuron.PipelineSupervisor, supervisor)
    end
  end
end

defmodule Neuron.Pipeline.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def init(opts) do
    owner = %{
      id: :owner,
      start: {Neuron.Pipeline.Owner, :start_link, [Keyword.fetch!(opts, :owner)]},
      restart: :temporary,
      significant: true
    }

    Supervisor.init([owner],
      strategy: :one_for_all,
      max_restarts: 0,
      auto_shutdown: :any_significant
    )
  end
end

defmodule Neuron.Pipeline.Source do
  use GenStage
  def start_link(items), do: GenStage.start_link(__MODULE__, items)
  def init(items), do: {:producer, items}

  def handle_demand(demand, items) do
    {events, remaining} = Enum.split(items, demand)
    {:noreply, events, remaining}
  end
end

defmodule Neuron.Pipeline.Mapper do
  use GenStage
  def start_link(args), do: GenStage.start_link(__MODULE__, args)

  def init({producer, fun}) do
    {:producer_consumer, fun, subscribe_to: [{producer, max_demand: 1, min_demand: 0}]}
  end

  def handle_events(events, _from, fun), do: {:noreply, Enum.map(events, fun), fun}
end

defmodule Neuron.Pipeline.Owner do
  @moduledoc false
  use GenServer
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  def init(owner), do: {:ok, Process.monitor(owner)}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, reference),
    do: {:stop, :normal, reference}
end
