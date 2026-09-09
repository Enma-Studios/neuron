defmodule Neuron.FSM do
  @moduledoc """
  Job-driven state machines. Transitions use optimistic concurrency and commit
  their state, event, and Oban job in one repository transaction.
  Guards are named functions on the definition module, receiving data and payload.
  """
  import Ecto.Query
  alias Neuron.FSM.{Machine, Event}
  alias Neuron.Persistence, as: P

  defmacro __using__(_) do
    quote do
      import Neuron.FSM.Definition, only: [state: 1, transition: 2]
      Module.register_attribute(__MODULE__, :states, accumulate: true)
      Module.register_attribute(__MODULE__, :transitions, accumulate: true)
      @before_compile Neuron.FSM
    end
  end

  defmacro __before_compile__(env) do
    states = env.module |> Module.get_attribute(:states) |> Enum.reverse()
    transitions = env.module |> Module.get_attribute(:transitions) |> Enum.reverse()

    for {_, opts} <- transitions do
      unless opts[:from] in states and opts[:to] in states, do: raise("unknown transition state")
    end

    quote do
      def states, do: unquote(states)
      def transitions, do: unquote(Macro.escape(transitions))
    end
  end

  def create(definition, data, opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    P.repo().transaction(fn ->
      machine =
        P.repo().insert!(%Machine{
          id: id,
          definition: Atom.to_string(definition),
          state: to_string(hd(definition.states())),
          data: P.encode(data)
        })

      record(machine, :created, %{})
      schedule(machine, Keyword.get(opts, :worker), 0)
      machine
    end)
  end

  def get(id), do: P.repo().get!(Machine, id)
  def data(%Machine{data: data}), do: P.decode(data)
  def state(id), do: get(id).state
  def definition(machine), do: String.to_existing_atom(machine.definition)

  def allowed_events(id) do
    machine = get(id)

    for {event, opts} <- definition(machine).transitions(),
        to_string(opts[:from]) == machine.state,
        do: event
  end

  def send(id, event, payload \\ %{}, opts \\ []) do
    P.repo().transaction(fn ->
      machine = get(id)
      if opts[:version] && opts[:version] != machine.version, do: P.repo().rollback(:stale)
      module = definition(machine)

      transition =
        Enum.find(module.transitions(), fn {name, spec} ->
          name == event and to_string(spec[:from]) == machine.state
        end)

      if is_nil(transition), do: P.repo().rollback({:invalid_event, machine.state, event})
      {_, spec} = transition
      current_data = data(machine)

      if spec[:guard] && !apply(module, spec[:guard], [current_data, payload]),
        do: P.repo().rollback(:guard_rejected)

      next_data = Map.merge(current_data, payload)
      query = from(m in Machine, where: m.id == ^id and m.version == ^machine.version)

      {count, _} =
        P.repo().update_all(query,
          set: [
            state: to_string(spec[:to]),
            version: machine.version + 1,
            data: P.encode(next_data),
            updated_at: DateTime.utc_now()
          ]
        )

      if count != 1, do: P.repo().rollback(:stale)
      next = get(id)
      record(next, event, payload)
      schedule(next, spec[:worker], Keyword.get(spec, :after, 0))
      next
    end)
  end

  def schedule_event(id, event, seconds) when is_integer(seconds) and seconds >= 0 do
    machine = get(id)

    %{"machine_id" => id, "version" => machine.version, "event" => to_string(event)}
    |> Neuron.FSM.Timer.new(schedule_in: seconds)
    |> then(&Oban.insert(P.oban(), &1))
  end

  defp schedule(_, nil, _), do: :ok

  defp schedule(machine, worker, delay) do
    seconds =
      case delay do
        {n, :seconds} -> n
        {n, :hours} -> n * 3600
        n -> n
      end

    options = if seconds == 0, do: [], else: [schedule_in: seconds]
    changeset = worker.new(%{"machine_id" => machine.id, "version" => machine.version}, options)
    {:ok, _} = Oban.insert(P.oban(), changeset)
  end

  defp record(machine, event, payload) do
    P.repo().insert!(%Event{
      machine_id: machine.id,
      version: machine.version,
      event: to_string(event),
      payload: P.encode(payload)
    })

    Neuron.Telemetry.emit([:fsm, :transition], %{
      run_id: machine.id,
      version: machine.version,
      state: machine.state,
      event: event
    })
  end
end

defmodule Neuron.FSM.Timer do
  use Oban.Worker, queue: :agents

  def perform(%Oban.Job{args: args}) do
    case Neuron.FSM.send(args["machine_id"], String.to_existing_atom(args["event"]), %{},
           version: args["version"]
         ) do
      {:ok, _} -> :ok
      {:error, :stale} -> :ok
      {:error, reason} -> {:cancel, inspect(reason)}
    end
  end
end

defmodule Neuron.FSM.Definition do
  defmacro state(name), do: quote(do: @states(unquote(name)))
  defmacro transition(event, opts), do: quote(do: @transitions({unquote(event), unquote(opts)}))
end
