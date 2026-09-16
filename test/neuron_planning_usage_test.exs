defmodule Neuron.PlanningUsageTest do
  use ExUnit.Case, async: false

  # Planning spends like any stage: intake fetches the seller page and asks
  # the model to read it, then may stop at needs_input. Each call records
  # usage with the options it was given, as the real providers do.
  defmodule Planner do
    def plan(_input, context) do
      :ok =
        Neuron.Usage.record_model(
          %{"usage" => %{"prompt_tokens" => 700, "completion_tokens" => 90}},
          Keyword.put(context.options, :model, "glm-5.3-flash")
        )

      :ok =
        Neuron.Usage.record_browser(3.5, Keyword.put(context.options, :provider, :browser_use))

      {:needs_input, %{questions: [], partial: %{}, reason: :missing_campaign_details}}
    end
  end

  test "a run that stops at needs_input still records its planning model call and browser session" do
    {:ok, id} = Neuron.start_run(Planner, %{})
    Oban.drain_queue(Neuron.Oban, queue: :orchestrators)

    assert %{status: :needs_input} = Neuron.get_run(id)

    usage = Neuron.Usage.snapshot(id)
    assert usage.total.model_calls == 1
    assert usage.total.prompt_tokens == 700
    assert usage.total.browser_sessions == 1
    assert %{model_calls: 1, browser_sessions: 1} = usage.by_stage["planning"]
  end

  test "a usage call with no run id is traced, not dropped silently" do
    handler = "usage-dropped-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      [:neuron, :usage, :dropped],
      fn _, _, metadata, _ -> send(test, {:dropped, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Neuron.Usage.record_model(%{"usage" => %{"prompt_tokens" => 1}}, stage: :prepare)
    assert_receive {:dropped, %{reason: :no_run_id, kind: "model", stage: :prepare}}
  end
end
