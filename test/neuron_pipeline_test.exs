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
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators)
    assert %{status: :processing, stage_index: 0} = Neuron.get_run(id)
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    assert %{status: :processing, stage_index: 1, stage_data: %{checkpoint: true}} = Neuron.get_run(id)
    Oban.drain_queue(Neuron.Oban, queue: :agents)
    assert %{status: :complete, leads: [%{name: "Ada"}]} = Neuron.get_run(id)
  end

  test "GenStage processes every item with bounded workers and cleans up supervision" do
    before = DynamicSupervisor.count_children(Neuron.PipelineSupervisor)
    result = Neuron.Pipeline.map(Enum.to_list(1..30), &(&1 * 2), max_concurrency: 3)
    assert Enum.sort(result) == Enum.map(1..30, &(&1 * 2))
    assert DynamicSupervisor.count_children(Neuron.PipelineSupervisor) == before
  end
end
