defmodule Neuron.StageAttemptsTest do
  use ExUnit.Case, async: false

  test "fetch gets two attempts, stages that call a model three, everything else two" do
    for stage <- [:fetch, :browse, :discover] do
      assert Neuron.StageWorker.attempts(stage) == 2, "#{stage}"
    end

    for stage <- [
          :prepare,
          :plan_search,
          :search,
          :draft,
          :normalize,
          :extract,
          :enrich
        ] do
      assert Neuron.StageWorker.attempts(stage) == 3, "#{stage}"
    end

    for stage <- [
          :retrieve,
          :dispatch,
          :collect,
          :rank,
          :finish,
          :evidence,
          :reconcile,
          :index,
          :persist
        ] do
      assert Neuron.StageWorker.attempts(stage) == 2, "#{stage}"
    end
  end

  defmodule Fetching do
    def plan(data, _), do: {:ok, data}
    def stages, do: [:fetch]
    def stage(:fetch, _data, _opts), do: {:error, :page_unreachable}
  end

  defmodule Normalizing do
    def plan(data, _), do: {:ok, data}
    def stages, do: [:normalize]
    def stage(:normalize, _data, _opts), do: {:error, {:zai_transport, :timeout}}
  end

  defp perform(id, attempt) do
    machine = Neuron.FSM.get(id)

    Neuron.StageWorker.perform(%Oban.Job{
      args: %{"machine_id" => id, "version" => machine.version},
      attempt: attempt,
      max_attempts: 3
    })
  end

  defp planned(profile) do
    {:ok, id} = Neuron.start_run(profile, %{})
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    id
  end

  test "a fetch that fails twice fails the run, naming the stage and attempts" do
    id = planned(Fetching)

    assert {:error, :page_unreachable} = perform(id, 1)
    assert %{status: :processing} = Neuron.get_run(id)

    assert :ok = perform(id, 2)

    assert %{status: :failed, error: :page_unreachable, exhausted: %{stage: :fetch, attempts: 2}} =
             Neuron.get_run(id)
  end

  test "a model stage gets a third attempt before the run fails" do
    id = planned(Normalizing)

    assert {:error, _} = perform(id, 1)
    assert {:error, _} = perform(id, 2)
    assert %{status: :processing} = Neuron.get_run(id)

    assert :ok = perform(id, 3)
    assert %{status: :failed, exhausted: %{stage: :normalize, attempts: 3}} = Neuron.get_run(id)
  end
end
