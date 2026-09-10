defmodule Neuron do
  @moduledoc "Embeddable API for durable, Oban-executed agents."
  alias Neuron.{FSM, Persistence}

  def start_run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    opts = Keyword.put_new(opts, :trace_id, Ecto.UUID.generate())
    Code.ensure_loaded!(profile)

    worker =
      if function_exported?(profile, :stages, 0),
        do: Neuron.PipelinePlanner,
        else: Neuron.RunWorker

    with {:ok, machine} <-
           FSM.create(
             Neuron.Run,
             %{profile: profile, input: input, opts: opts, result: nil, error: nil},
             id: Keyword.get(opts, :id, Ecto.UUID.generate()),
             worker: worker
           ),
         do: {:ok, machine.id}
  end

  def run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    with {:ok, id} <- start_run(profile, input, opts),
         do: await_run(id, Keyword.get(opts, :timeout, 120_000))
  end

  def get_run(id) do
    machine = reconcile_run(id)
    data = FSM.data(machine)
    FSM.definition(machine)

    status = String.to_existing_atom(machine.state)

    snapshot =
      Map.merge(data, %{
        id: id,
        status: status,
        version: machine.version,
        # Additive: `usage` is always present and `error_class` only when the
        # run carries an error. No existing key changes shape.
        usage: Neuron.Usage.snapshot(id)
      })

    snapshot =
      case Neuron.Usage.error_class(data[:error]) do
        nil -> snapshot
        class -> Map.put(snapshot, :error_class, class)
      end

    if is_map(data[:result]) do
      Enum.reduce(
        [:leads, :people, :posts, :organization, :campaign, :target_profile],
        snapshot,
        fn key, acc ->
          value = Map.get(data.result, key, Map.get(data.result, to_string(key)))
          if is_nil(value), do: acc, else: Map.put(acc, key, value)
        end
      )
    else
      snapshot
    end
  end

  @doc "Reconcile a discarded or externally cancelled current Oban job with its run."
  def reconcile_run(id) do
    import Ecto.Query
    machine = FSM.get(id)

    if machine.state in ["planning", "executing", "processing"] do
      abandoned =
        Persistence.repo().exists?(
          from(j in Oban.Job,
            where:
              j.args["machine_id"] == ^id and j.args["version"] == ^machine.version and
                j.state in ["discarded", "cancelled"] and
                j.worker in ["Neuron.RunWorker", "Neuron.PipelinePlanner", "Neuron.StageWorker"]
          )
        )

      if abandoned do
        case FSM.send(id, :failed, %{error: :job_abandoned}, version: machine.version) do
          {:ok, updated} -> updated
          {:error, :stale} -> FSM.get(id)
        end
      else
        machine
      end
    else
      machine
    end
  end

  def list_runs, do: Persistence.repo().all(FSM.Machine) |> Enum.map(&get_run(&1.id))
  def events(id), do: Neuron.Storage.events(id)

  def cancel_run(id) do
    with {:ok, machine} <- FSM.send(id, :cancel) do
      data = FSM.data(machine)

      if data[:profile] == Neuron.Coordinator.Campaign do
        children = get_in(data, [:stage_data, :children]) || []
        pending = get_in(data, [:stage_data, :pending_children]) || []

        for child <- Enum.uniq_by(children ++ pending, & &1.id),
            saved = Persistence.repo().get(FSM.Machine, child.id),
            saved && saved.state not in ["complete", "failed", "cancelled"] do
          FSM.send(child.id, :cancel)
        end
      end

      {:ok, machine}
    end
  end

  def provide_run(id, input) do
    data = id |> FSM.get() |> FSM.data()
    partial = if is_map(data.result), do: data.result[:partial] || %{}, else: %{}
    merged = data.input |> Map.merge(partial) |> Map.merge(input)
    FSM.send(id, :provided, %{input: merged, result: nil})
  end

  def resume_run(id) do
    data = id |> reconcile_run() |> FSM.data()
    event = if Map.has_key?(data, :stage_index), do: :retry_pipeline, else: :retry
    FSM.send(id, event, %{error: nil})
  end

  def spawn_agent(run_id, role, worker \\ Neuron.Agent.Echo, input, opts \\ []) do
    start_run(Neuron.Agent, %{worker: worker, input: input, parent_id: run_id, role: role}, opts)
  end

  def get_agent(id), do: get_run(id)
  def cancel_agent(id), do: cancel_run(id)

  def await_run(id, timeout \\ 120_000),
    do: await(id, System.monotonic_time(:millisecond) + timeout)

  defp await(id, deadline) do
    result = get_run(id)

    cond do
      result.status == :complete ->
        {:ok, result}

      result.status == :needs_input ->
        {:needs_input, result}

      result.status in [:failed, :cancelled] ->
        {:error, result}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(25)
        await(id, deadline)
    end
  end
end
