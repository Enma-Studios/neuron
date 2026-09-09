defmodule Neuron.Run do
  @moduledoc "A durable coordinator state machine."

  @behaviour :gen_statem

  defstruct [:id, :profile, :input, :plan, :result, :error, :opts]

  def start_link({id, profile, input, opts}) do
    :gen_statem.start_link(
      {:via, Registry, {Neuron.RunRegistry, id}},
      __MODULE__,
      {id, profile, input, opts},
      []
    )
  end

  def child_spec({id, profile, input, opts}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{id, profile, input, opts}]},
      type: :worker
    }
  end

  def call(id, request), do: :gen_statem.call(Neuron.RunRegistry.via(id), request)

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({id, profile, input, opts}) do
    now = DateTime.utc_now()
    run = {:neuron_run, id, profile, input, :queued, now, now, nil, nil}
    :ok = Neuron.Storage.put_run(run, %{run_id: id, task_id: "coordinator:init"})
    _ = Neuron.Storage.next_event(id, :run_created, %{profile: profile})

    {:ok, :queued, %__MODULE__{id: id, profile: profile, input: input, opts: opts},
     [{:next_event, :internal, :plan}]}
  end

  def queued(:internal, :plan, data) do
    persist_status(data, :planning)
    {:next_state, :planning, data, [{:next_event, :internal, :run_plan}]}
  end

  def queued({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :queued)}]}

  def queued({:call, from}, :cancel, data), do: cancel(from, data)

  def planning(:internal, :run_plan, data) do
    case data.profile.plan(data.input, context(data)) do
      {:ok, plan} ->
        data = %{data | plan: plan}
        persist_status(data, :executing)
        {:next_state, :executing, data, [{:next_event, :internal, :execute}]}

      {:needs_input, details} ->
        data = %{data | result: details}
        persist_status(data, :needs_input, details, nil)
        {:next_state, :needs_input, data}

      {:error, reason} ->
        fail(data, reason)
    end
  end

  def planning({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :planning)}]}

  def planning({:call, from}, :cancel, data), do: cancel(from, data)

  def needs_input({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :needs_input)}]}

  def needs_input({:call, from}, {:provide, input}, data) when is_map(input) do
    data = %{data | input: Map.merge(data.input || %{}, input), result: nil, error: nil}
    persist_status(data, :planning)
    {:next_state, :planning, data, [{:next_event, :internal, :run_plan}, {:reply, from, :ok}]}
  end

  def needs_input({:call, from}, :cancel, data), do: cancel(from, data)

  def executing(:internal, :execute, data) do
    operation = operation_id(data)

    _ =
      Neuron.Storage.put_operation(
        {:neuron_operation, operation, data.id, data.id, :coordinator, 1, :started, data.plan,
         nil, DateTime.utc_now()},
        %{run_id: data.id, agent_id: data.id, task_id: "coordinator:operation"}
      )

    case data.profile.run(data.plan, context(data)) do
      {:ok, result} ->
        _ =
          Neuron.Storage.put_operation(
            {:neuron_operation, operation, data.id, data.id, :coordinator, 1, :completed,
             data.plan, result, DateTime.utc_now()},
            %{run_id: data.id, agent_id: data.id, task_id: "coordinator:operation"}
          )

        complete(%{data | result: result})

      {:error, reason} ->
        fail(data, reason)
    end
  end

  def executing({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :executing)}]}

  def executing({:call, from}, :cancel, data), do: cancel(from, data)

  def complete({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :complete)}]}

  def complete({:call, from}, :cancel, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :already_complete}}]}

  def complete(_event_type, _event, data), do: {:keep_state, data}

  def failed({:call, from}, :get, data),
    do: {:keep_state_and_data, [{:reply, from, snapshot(data, :failed)}]}

  def failed({:call, from}, :cancel, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :already_failed}}]}

  def failed(_event_type, _event, data), do: {:keep_state, data}

  defp context(data), do: %{run_id: data.id, options: data.opts, plan: data.plan}

  defp complete(data) do
    persist_status(data, :complete, data.result, nil)
    _ = Neuron.Storage.next_event(data.id, :run_completed, %{result: data.result})
    {:next_state, :complete, data}
  end

  defp fail(data, reason) do
    data = %{data | error: reason}
    persist_status(data, :failed, nil, reason)
    _ = Neuron.Storage.next_event(data.id, :run_failed, %{error: inspect(reason)})
    {:next_state, :failed, data}
  end

  defp cancel(from, data) do
    persist_status(data, :cancelled, nil, :cancelled)
    _ = Neuron.Storage.next_event(data.id, :run_cancelled, %{})
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  defp persist_status(data, status, result \\ nil, error \\ nil) do
    Neuron.Telemetry.emit([:run, :state], %{
      run_id: data.id,
      task_id: "coordinator",
      status: status,
      result: Neuron.Telemetry.summarize(result),
      error: inspect(error)
    })

    now = DateTime.utc_now()

    _ =
      Neuron.Storage.put_run(
        {:neuron_run, data.id, data.profile, data.input, status, now, now, result, error},
        %{run_id: data.id, task_id: "coordinator:state"}
      )

    _ = Neuron.Storage.next_event(data.id, :status_changed, %{status: status})
    :ok
  end

  defp operation_id(data), do: "#{data.id}:coordinator:1"

  defp snapshot(data, status),
    do:
      %{
        id: data.id,
        status: status,
        profile: data.profile,
        result: data.result,
        error: data.error
      }
      |> expose_result_fields(data.result)

  defp expose_result_fields(snapshot, result) when is_map(result) do
    Enum.reduce(
      [:leads, :campaign, :target_profile, :organization, :people, :posts],
      snapshot,
      fn key, acc ->
        value = Map.get(result, key, Map.get(result, Atom.to_string(key)))
        if is_nil(value), do: acc, else: Map.put(acc, key, value)
      end
    )
  end

  defp expose_result_fields(snapshot, _result), do: snapshot
end
