defmodule Neuron do
  @moduledoc "Embeddable API for durable, Oban-executed agents."
  alias Neuron.{FSM, Persistence}

  def start_run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    with {:ok, machine} <-
           FSM.create(
             Neuron.Run,
             %{profile: profile, input: input, opts: opts, result: nil, error: nil},
             id: Keyword.get(opts, :id, Ecto.UUID.generate()),
             worker: Neuron.RunWorker
           ),
         do: {:ok, machine.id}
  end

  def run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    with {:ok, id} <- start_run(profile, input, opts),
         do: await_run(id, Keyword.get(opts, :timeout, 120_000))
  end

  def get_run(id) do
    machine = FSM.get(id)
    data = FSM.data(machine)

    snapshot =
      Map.merge(data, %{
        id: id,
        status: String.to_existing_atom(machine.state),
        version: machine.version
      })

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

  def list_runs, do: Persistence.repo().all(FSM.Machine) |> Enum.map(&get_run(&1.id))
  def events(id), do: Neuron.Storage.events(id)
  def cancel_run(id), do: FSM.send(id, :cancel)

  def provide_run(id, input) do
    data = id |> FSM.get() |> FSM.data()
    FSM.send(id, :provided, %{input: Map.merge(data.input, input), result: nil})
  end

  def resume_run(id), do: FSM.send(id, :retry)

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
