defmodule Neuron.GraphConflictTest do
  use ExUnit.Case, async: false

  # The error the acceptance run for neureni#43 actually produced, six times.
  defp abort do
    {:error,
     %{
       reason: %{status: 10, message: "Transaction has been aborted. Please retry"},
       action: :execute
     }}
  end

  defp fixture_run do
    {:ok, machine} =
      Neuron.FSM.create(
        Neuron.Run,
        %{profile: Neuron.Agent.Echo, input: %{}, opts: [], result: nil, error: nil},
        id: Ecto.UUID.generate()
      )

    machine.id
  end

  defp counting(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fun = fn ->
      Agent.get_and_update(agent, fn
        [head | rest] -> {head, rest}
        [] -> {{:ok, %{}}, []}
      end)
    end

    {fun, fn -> Agent.get(agent, &length/1) end}
  end

  test "a transient abort succeeds on retry" do
    {fun, remaining} = counting([abort(), abort(), {:ok, %{"data" => "written"}}])

    assert {:ok, %{"data" => "written"}} =
             Neuron.Graph.with_conflict_retry([graph_conflict_backoff_ms: 0], fun)

    # All three queued results were consumed: it really did retry twice.
    assert remaining.() == 0
  end

  test "an abort that exhausts its retries is returned and counted against the run" do
    run = fixture_run()
    {fun, _remaining} = counting(List.duplicate(abort(), 10))

    assert {:error, _} =
             Neuron.Graph.with_conflict_retry(
               [graph_conflict_backoff_ms: 0, graph_conflict_attempts: 3, run_id: run],
               fun
             )

    assert Neuron.get_run(run).usage.total.graph_conflicts == 1
  end

  test "a conflict the retry absorbs is not counted as a loss" do
    run = fixture_run()
    {fun, _remaining} = counting([abort(), {:ok, %{}}])

    assert {:ok, _} =
             Neuron.Graph.with_conflict_retry(
               [graph_conflict_backoff_ms: 0, run_id: run],
               fun
             )

    assert Neuron.get_run(run).usage.total.graph_conflicts == 0
  end

  test "an error that is not an abort is returned on the first attempt" do
    run = fixture_run()
    {fun, remaining} = counting([{:error, :schema_violation}, {:ok, %{}}])

    assert {:error, :schema_violation} =
             Neuron.Graph.with_conflict_retry(
               [graph_conflict_backoff_ms: 0, run_id: run],
               fun
             )

    # The second result was never reached, so nothing retried.
    assert remaining.() == 1
    assert Neuron.get_run(run).usage.total.graph_conflicts == 0
  end

  test "a campaign counts the conflicts its ingestion children exhausted" do
    parent = fixture_run()

    for _ <- 1..3 do
      {fun, _} = counting(List.duplicate(abort(), 5))

      {:error, _} =
        Neuron.Graph.with_conflict_retry(
          [
            graph_conflict_backoff_ms: 0,
            graph_conflict_attempts: 2,
            run_id: Ecto.UUID.generate(),
            parent_run_id: parent,
            stage: :reconcile
          ],
          fun
        )
    end

    usage = Neuron.get_run(parent).usage
    assert usage.total.graph_conflicts == 3
    assert usage.by_stage["reconcile"].graph_conflicts == 3
  end

  describe "conflict?/1" do
    test "recognises an abort by status and by Dgraph's own wording" do
      assert Neuron.Graph.conflict?(%{reason: %{status: 10}})
      assert Neuron.Graph.conflict?(%{status: 10})
      assert Neuron.Graph.conflict?("Transaction has been aborted. Please retry")
      assert Neuron.Graph.conflict?({:dlex, "Transaction has been aborted. Please retry"})
    end

    test "does not treat other failures as retryable" do
      refute Neuron.Graph.conflict?(:schema_violation)
      refute Neuron.Graph.conflict?(%{status: 5})
      refute Neuron.Graph.conflict?("connection refused")
    end
  end

  test "backoff is bounded: exhausting the default attempts is not open-ended" do
    {fun, _} = counting(List.duplicate(abort(), 20))

    {elapsed, {:error, _}} =
      :timer.tc(fn ->
        Neuron.Graph.with_conflict_retry([graph_conflict_backoff_ms: 1], fun)
      end)

    # Five attempts at a 1ms base cannot take anywhere near a second.
    assert elapsed < 1_000_000
  end
end
