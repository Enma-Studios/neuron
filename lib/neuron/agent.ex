defmodule Neuron.Agent.Worker do
  @moduledoc "Behaviour for a unit of delegated agent work."
  @callback run(input :: term(), context :: map()) :: {:ok, term()} | {:error, term()}
end

defmodule Neuron.Agent.Echo do
  @behaviour Neuron.Agent.Worker
  @impl true
  def run(input, _context), do: {:ok, input}
end

defmodule Neuron.Agent do
  @moduledoc "Durable delegated work state machine."
  @behaviour :gen_statem

  defstruct [:id, :run_id, :parent_id, :role, :worker, :input, :result, :error, :opts]

  def start_link({id, run_id, parent_id, role, worker, input, opts}) do
    :gen_statem.start_link(
      {:via, Registry, {Neuron.RunRegistry, {:agent, id}}},
      __MODULE__,
      {id, run_id, parent_id, role, worker, input, opts},
      []
    )
  end

  def child_spec(args),
    do: %{
      id: {__MODULE__, elem(args, 0)},
      start: {__MODULE__, :start_link, [args]},
      type: :worker
    }

  def call(id, request),
    do: :gen_statem.call({:via, Registry, {Neuron.RunRegistry, {:agent, id}}}, request)

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({id, run_id, parent_id, role, worker, input, opts}) do
    now = DateTime.utc_now()

    _ =
      Neuron.Storage.put_agent(
        {:neuron_agent, id, run_id, parent_id, role, :queued, %{input: input, worker: worker},
         now},
        %{run_id: run_id, agent_id: id, task_id: "agent:init"}
      )

    _ =
      Neuron.Storage.next_event(run_id, :agent_created, %{
        agent_id: id,
        parent_id: parent_id,
        role: role
      })

    data = %__MODULE__{
      id: id,
      run_id: run_id,
      parent_id: parent_id,
      role: role,
      worker: worker,
      input: input,
      opts: opts
    }

    {:ok, :queued, data, [{:next_event, :internal, :execute}]}
  end

  def queued(:internal, :execute, data) do
    persist(data, :executing)
    {:next_state, :executing, data, [{:next_event, :internal, :run}]}
  end

  def queued({:call, from}, :get, data), do: reply(from, data, :queued)
  def queued({:call, from}, :cancel, data), do: stop_cancel(from, data)

  def executing(:internal, :run, data) do
    metadata =
      Neuron.Telemetry.trace_metadata(data.opts)
      |> Map.merge(%{run_id: data.run_id, agent_id: data.id, task_id: data.role})

    result =
      Neuron.Telemetry.span([:agent, :task], metadata, fn ->
        data.worker.run(data.input, %{
          run_id: data.run_id,
          agent_id: data.id,
          parent_id: data.parent_id
        })
      end)

    case result do
      {:ok, value} ->
        persist(data, :complete, value, nil)

        _ =
          Neuron.Storage.next_event(data.run_id, :agent_completed, %{
            agent_id: data.id,
            result: Neuron.Telemetry.summarize(value)
          })

        {:next_state, :complete, %{data | result: value}}

      {:error, reason} ->
        persist(data, :failed, nil, reason)

        _ =
          Neuron.Storage.next_event(data.run_id, :agent_failed, %{
            agent_id: data.id,
            error: inspect(reason)
          })

        {:next_state, :failed, %{data | error: reason}}
    end
  end

  def executing({:call, from}, :get, data), do: reply(from, data, :executing)
  def executing({:call, from}, :cancel, data), do: stop_cancel(from, data)

  def complete({:call, from}, :get, data), do: reply(from, data, :complete)

  def complete({:call, from}, :cancel, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :already_complete}}]}

  def failed({:call, from}, :get, data), do: reply(from, data, :failed)

  def failed({:call, from}, :cancel, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :already_failed}}]}

  defp reply(from, data, status),
    do:
      {:keep_state_and_data,
       [
         {:reply, from,
          %{
            id: data.id,
            run_id: data.run_id,
            role: data.role,
            status: status,
            result: data.result,
            error: data.error
          }}
       ]}

  defp stop_cancel(from, data) do
    persist(data, :cancelled, nil, :cancelled)
    _ = Neuron.Storage.next_event(data.run_id, :agent_cancelled, %{agent_id: data.id})
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  defp persist(data, status, result \\ nil, error \\ nil) do
    _ =
      Neuron.Storage.put_agent(
        {:neuron_agent, data.id, data.run_id, data.parent_id, data.role, status,
         %{input: data.input, result: result, error: error, worker: data.worker},
         DateTime.utc_now()},
        %{run_id: data.run_id, agent_id: data.id, task_id: data.role}
      )

    Neuron.Telemetry.emit([:agent, :state], %{
      run_id: data.run_id,
      agent_id: data.id,
      role: data.role,
      status: status,
      result: Neuron.Telemetry.summarize(result),
      error: inspect(error)
    })

    :ok
  end
end
