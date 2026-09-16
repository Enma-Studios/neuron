defmodule Neuron.Run do
  @moduledoc "Durable planning, execution, approval, cancellation, and completion states."
  use Neuron.FSM
  state(:planning)
  state(:executing)
  state(:processing)
  state(:needs_input)
  state(:complete)
  state(:failed)
  state(:cancelled)
  transition(:pipeline, from: :planning, to: :processing, worker: Neuron.StageWorker)
  transition(:progress, from: :processing, to: :processing, worker: Neuron.StageWorker)
  transition(:finished, from: :processing, to: :complete)
  transition(:failed, from: :processing, to: :failed)
  transition(:cancel, from: :processing, to: :cancelled)
  transition(:planned, from: :planning, to: :executing, worker: Neuron.RunWorker)
  transition(:needs_input, from: :planning, to: :needs_input)
  transition(:provided, from: :needs_input, to: :planning, worker: Neuron.RunWorker)
  transition(:finished, from: :executing, to: :complete)
  transition(:failed, from: :planning, to: :failed)
  transition(:failed, from: :executing, to: :failed)
  transition(:retry_pipeline, from: :failed, to: :processing, worker: Neuron.StageWorker)
  transition(:retry, from: :failed, to: :planning, worker: Neuron.RunWorker)
  transition(:cancel, from: :planning, to: :cancelled)
  transition(:cancel, from: :executing, to: :cancelled)
  transition(:cancel, from: :needs_input, to: :cancelled)
  transition(:cancel, from: :failed, to: :cancelled)
end

defmodule Neuron.RunWorker do
  use Oban.Worker, queue: :orchestrators, max_attempts: 5

  def perform(%Oban.Job{args: %{"machine_id" => id, "version" => version}} = job) do
    machine = Neuron.FSM.get(id)

    if machine.version == version do
      data = Neuron.FSM.data(machine)
      context = %{run_id: id, options: data.opts, plan: data[:plan]}

      result =
        case machine.state do
          "planning" -> data.profile.plan(data.input, context)
          "executing" -> data.profile.run(data.plan, context)
        end

      case result do
        {:ok, value} when machine.state == "planning" ->
          if function_exported?(data.profile, :stages, 0) do
            advance(id, version, :pipeline, %{plan: value, stage_index: 0, stage_data: value})
          else
            advance(id, version, :planned, %{plan: value})
          end

        {:ok, value} ->
          advance(id, version, :finished, %{result: value, error: nil})

        {:needs_input, details} ->
          advance(id, version, :needs_input, %{result: details})

        {:approval_required, details} ->
          advance(id, version, :needs_input, %{result: details})

        {:error, reason} when job.attempt < job.max_attempts ->
          {:error, reason}

        {:error, reason} ->
          advance(id, version, :failed, %{error: reason})
      end
    else
      :ok
    end
  rescue
    error ->
      if job.attempt == job.max_attempts do
        advance(id, version, :failed, %{error: Exception.format(:error, error, __STACKTRACE__)})
      end

      reraise error, __STACKTRACE__
  end

  def advance(id, version, event, payload) do
    case Neuron.FSM.send(id, event, payload, version: version) do
      {:ok, _} -> :ok
      {:error, :stale} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Neuron.StageWorker do
  @moduledoc "Executes one checkpointed pipeline stage per Oban job."
  use Oban.Worker, queue: :agents, max_attempts: 5

  # The backstop behind each stage's own bounds: without it Oban lets a stuck
  # attempt run forever, and the stage is never retried or failed.
  def timeout(_job), do: Application.get_env(:neuron, :stage_timeout, :timer.minutes(15))

  def perform(%Oban.Job{args: %{"machine_id" => id, "version" => version}} = job) do
    machine = Neuron.FSM.get(id)

    if machine.version != version do
      :ok
    else
      data = Neuron.FSM.data(machine)
      stages = data.profile.stages()
      stage = Enum.fetch!(stages, data.stage_index)

      opts =
        data.opts
        |> Keyword.put(:run_id, id)
        |> Keyword.put(:stage, stage)
        |> Keyword.put(:transition_version, machine.version)

      run_stage = fn -> data.profile.stage(stage, data.stage_data, opts) end

      # A job Oban has snoozed is a stage polling, not starting: counted as a
      # stage start, one hung child turned `collect` into hundreds of them.
      result =
        case job.meta["snoozed"] do
          snoozed when is_integer(snoozed) and snoozed > 0 ->
            Neuron.Telemetry.emit([:pipeline, :stage, :wait], %{
              run_id: id,
              stage: stage,
              snoozed: snoozed
            })

            run_stage.()

          _ ->
            Neuron.Telemetry.span([:pipeline, :stage], %{run_id: id, stage: stage}, run_stage)
        end

      case result do
        {:ok, output} ->
          if data.stage_index + 1 == length(stages) do
            Neuron.RunWorker.advance(id, version, :finished, %{result: output, stage_data: nil})
          else
            Neuron.RunWorker.advance(id, version, :progress, %{
              stage_data: output,
              stage_index: data.stage_index + 1
            })
          end

        {:wait, seconds} when is_integer(seconds) and seconds > 0 ->
          {:snooze, seconds}

        {:goto, next_stage, output} ->
          index = Enum.find_index(stages, &(&1 == next_stage))
          true = is_integer(index)

          Neuron.RunWorker.advance(id, version, :progress, %{
            stage_data: output,
            stage_index: index
          })

        {:error, reason} when job.attempt < job.max_attempts ->
          {:error, reason}

        {:error, reason} ->
          Neuron.RunWorker.advance(id, version, :failed, %{error: reason})
      end
    end
  rescue
    error ->
      if job.attempt == job.max_attempts do
        Neuron.RunWorker.advance(id, version, :failed, %{
          error: Exception.format(:error, error, __STACKTRACE__)
        })
      end

      reraise error, __STACKTRACE__
  end
end

defmodule Neuron.PipelinePlanner do
  use Oban.Worker, queue: :agents, max_attempts: 5
  defdelegate perform(job), to: Neuron.RunWorker
end
