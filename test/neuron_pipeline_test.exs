defmodule Neuron.PipelineTest do
  use ExUnit.Case, async: false

  defmodule Profile do
    def plan(input, _), do: {:ok, input}
    def stages, do: [:first, :second]
    def stage(:first, data, _), do: {:ok, Map.put(data, :checkpoint, true)}
    def stage(:second, %{checkpoint: true} = data, _), do: {:ok, data}
  end

  test "pipeline checkpoints one stage per job" do
    {:ok, id} = Neuron.start_run(Profile, %{leads: [%{name: "Ada"}]})
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    assert %{status: :processing, stage_index: 0} = Neuron.get_run(id)
    Oban.drain_queue(Neuron.Oban, queue: :agents)

    assert %{status: :processing, stage_index: 1, stage_data: %{checkpoint: true}} =
             Neuron.get_run(id)

    Oban.drain_queue(Neuron.Oban, queue: :agents)
    assert %{status: :complete, leads: [%{name: "Ada"}]} = Neuron.get_run(id)
  end

  test "pipeline supervision stops when its owning job is killed" do
    parent = self()

    owner =
      spawn(fn ->
        Neuron.Pipeline.map(
          [:work],
          fn _ ->
            send(parent, {:mapper, self()})

            receive do
              :finish -> :ok
            end
          end, max_concurrency: 1)
      end)

    assert_receive {:mapper, mapper}, 1_000
    monitor = Process.monitor(mapper)
    [{_, supervisor, _, _}] = DynamicSupervisor.which_children(Neuron.PipelineSupervisor)
    supervisor_monitor = Process.monitor(supervisor)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mapper, _}, 1_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _}, 1_000
    assert DynamicSupervisor.count_children(Neuron.PipelineSupervisor).active == 0
  end

  test "GenStage processes every item with bounded workers and cleans up supervision" do
    before = DynamicSupervisor.count_children(Neuron.PipelineSupervisor)
    result = Neuron.Pipeline.map(Enum.to_list(1..30), &(&1 * 2), max_concurrency: 3)
    assert Enum.sort(result) == Enum.map(1..30, &(&1 * 2))
    assert DynamicSupervisor.count_children(Neuron.PipelineSupervisor) == before
  end
end

defmodule Neuron.RecoveryTest do
  use ExUnit.Case, async: false

  defmodule Failing do
    def plan(data, _), do: {:ok, data}
    def stages, do: [:first, :fail]
    def stage(:first, data, _), do: {:ok, Map.put(data, :saved, true)}
    def stage(:fail, _, _), do: raise("stage unavailable")
  end

  defmodule InvalidWorker do
    def new(args, _opts), do: Oban.Job.new(args, worker: "InvalidWorker", priority: -1)
  end

  test "exhausted crashes retain the checkpoint and can resume" do
    {:ok, id} = Neuron.start_run(Failing, %{})
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    machine = Neuron.FSM.get(id)

    assert_raise RuntimeError, "stage unavailable", fn ->
      Neuron.StageWorker.perform(%Oban.Job{
        args: %{"machine_id" => id, "version" => machine.version},
        attempt: 5,
        max_attempts: 5
      })
    end

    assert %{status: :failed, stage_index: 1, stage_data: %{saved: true}} = Neuron.get_run(id)
    assert {:ok, %{state: "processing"}} = Neuron.resume_run(id)
    assert %{stage_index: 1, stage_data: %{saved: true}} = Neuron.get_run(id)
    Neuron.cancel_run(id)
  end

  test "failed job insertion rolls back machine and history" do
    id = Ecto.UUID.generate()

    assert_raise MatchError, fn ->
      Neuron.FSM.create(Neuron.Run, %{}, id: id, worker: InvalidWorker)
    end

    assert is_nil(Neuron.Persistence.repo().get(Neuron.FSM.Machine, id))
    assert Neuron.events(id) == []
  end

  test "delayed events become harmless when the version changes" do
    {:ok, id} = Neuron.start_run(Neuron.Coordinator.Default, %{})
    {:ok, timer} = Neuron.FSM.schedule_event(id, :cancel, 3_600)
    assert timer.state == "scheduled"
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators, with_recursion: true)
    assert :ok = Neuron.FSM.Timer.perform(timer)
    assert Neuron.get_run(id).status == :complete
  end

  test "discarded jobs surface as failed runs and can be resumed" do
    import Ecto.Query
    {:ok, id} = Neuron.start_run(Neuron.Coordinator.Default, %{leads: []})

    Neuron.Persistence.repo().update_all(from(j in Oban.Job, where: j.args["machine_id"] == ^id),
      set: [state: "discarded"]
    )

    assert %{status: :failed, error: :job_abandoned} = Neuron.get_run(id)
    assert {:ok, _} = Neuron.resume_run(id)
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators, with_recursion: true)
    assert %{status: :complete, leads: []} = Neuron.get_run(id)
  end

  test "rejects process-local data before persistence" do
    assert_raise ArgumentError, ~r/durable data/, fn -> Neuron.start_run(%{owner: self()}) end
  end
end
