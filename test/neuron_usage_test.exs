defmodule Neuron.UsageTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  defp fixture_run(state, data) do
    {:ok, machine} =
      Neuron.FSM.create(
        Neuron.Run,
        Map.merge(
          %{profile: Neuron.Agent.Echo, input: %{}, opts: [], result: nil, error: nil},
          data
        ),
        id: Ecto.UUID.generate()
      )

    if state != "planning" do
      Neuron.Persistence.repo().update_all(
        from(m in Neuron.FSM.Machine, where: m.id == ^machine.id),
        set: [state: state]
      )
    end

    machine.id
  end

  test "a fixture run reports non-zero usage per stage and in total" do
    run = fixture_run("complete", %{result: %{}})
    child = Ecto.UUID.generate()

    :ok =
      Neuron.Usage.record_model(
        %{"usage" => %{"prompt_tokens" => 900, "completion_tokens" => 120}},
        run_id: run,
        stage: :plan_search,
        model: "glm-5.3-flash"
      )

    :ok =
      Neuron.Usage.record_model(
        %{"usage" => %{"prompt_tokens" => 300, "completion_tokens" => 40}},
        run_id: run,
        stage: :search,
        model: "glm-5.3-flash"
      )

    :ok = Neuron.Usage.record_browser(12.5, run_id: run, stage: :search, provider: :browser_use)

    # An ingestion child's spend belongs to the campaign that dispatched it.
    :ok =
      Neuron.Usage.record_model(
        %{"usage" => %{"prompt_tokens" => 50, "completion_tokens" => 10}},
        run_id: child,
        parent_run_id: run,
        stage: :evidence,
        model: "glm-5.3-flash"
      )

    :ok =
      Neuron.Usage.record_browser(4.0,
        run_id: child,
        parent_run_id: run,
        stage: :fetch,
        provider: :browser_use
      )

    usage = Neuron.get_run(run).usage

    assert usage.total == %{
             model_calls: 3,
             prompt_tokens: 1250,
             cached_tokens: 0,
             completion_tokens: 170,
             browser_sessions: 2,
             browser_seconds: 16.5,
             graph_conflicts: 0
           }

    assert [%{label: "glm-5.3-flash", model_calls: 3, prompt_tokens: 1250}] = usage.models
    assert [%{label: "browser_use", browser_sessions: 2, browser_seconds: 16.5}] = usage.browser

    assert usage.by_stage["plan_search"].prompt_tokens == 900
    assert usage.by_stage["search"].completion_tokens == 40
    assert usage.by_stage["search"].browser_seconds == 12.5
    assert usage.by_stage["fetch"].browser_sessions == 1
  end

  test "a run with no recorded calls reports zeroed usage rather than nothing" do
    snapshot = Neuron.get_run(fixture_run("complete", %{result: %{}}))

    assert snapshot.usage.total.model_calls == 0
    assert snapshot.usage.models == []
    assert snapshot.usage.by_stage == %{}
    refute Map.has_key?(snapshot, :error_class)
  end

  describe "error_class/1" do
    test "names the subsystem a failed run's error came from" do
      classes = %{
        {:search_unavailable, [%{engine: "google", kind: :consent_wall}]} => :search,
        {:zai_transport, %{reason: :timeout}} => :model,
        {:invalid_model_output, {:error, :expected_results}} => :model,
        {:browser_use_start, :nxdomain} => :browser,
        {:fleet_no_sessions, []} => :browser,
        "%Dlex.Error{reason: %GRPC.RPCError{status: 10}}" => :storage,
        {:budget_exceeded, 500} => :budget
      }

      for {error, expected} <- classes do
        assert Neuron.Usage.error_class(error) == expected,
               "expected #{inspect(error)} to classify as #{expected}"
      end
    end

    test "an unrecognised error is unknown, and no error has no class" do
      assert Neuron.Usage.error_class({:something_nobody_has_seen, 1}) == :unknown
      assert Neuron.Usage.error_class(nil) == nil
    end
  end

  test "a failed fixture run carries the right error class" do
    run = fixture_run("failed", %{error: {:search_unavailable, [%{engine: "google"}]}})

    snapshot = Neuron.get_run(run)

    assert snapshot.status == :failed
    assert snapshot.error_class == :search
  end

  test "a failed fixture run whose error is a storage fault classifies as storage" do
    run =
      fixture_run("failed", %{
        error: "** (Dlex.Error) Transaction has been aborted. Please retry"
      })

    assert Neuron.get_run(run).error_class == :storage
  end
end
