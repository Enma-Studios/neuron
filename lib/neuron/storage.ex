defmodule Neuron.Storage do
  @moduledoc """
  Durable execution storage.

  Agent execution state lives in Mnesia. When `mnesia_rocksdb` is available,
  tables use its `rocksdb_copies` backend; otherwise the configured Mnesia
  backend is used. Domain facts are deliberately published elsewhere.
  """

  use GenServer

  require Logger

  @tables [
    {:neuron_run, [:id, :profile, :input, :status, :inserted_at, :updated_at, :result, :error]},
    {:neuron_agent, [:id, :run_id, :parent_id, :role, :status, :state, :updated_at]},
    {:neuron_operation,
     [:id, :run_id, :agent_id, :kind, :attempt, :status, :request, :response, :updated_at]},
    {:neuron_event, [:key, :run_id, :sequence, :type, :payload, :inserted_at]},
    {:neuron_outbox, [:id, :run_id, :kind, :payload, :status, :attempts, :updated_at]}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def transaction(fun, metadata \\ %{}) do
    Neuron.Telemetry.span([:db, :transaction], metadata, fn -> :mnesia.transaction(fun) end)
  end

  def put_run(run, metadata \\ %{}), do: write(:neuron_run, run, metadata)
  def get_run(id), do: read(:neuron_run, id, %{run_id: id})

  def list_runs do
    transaction(fn -> :mnesia.match_object({:neuron_run, :_, :_, :_, :_, :_, :_, :_, :_}) end, %{
      task_id: "runs:list"
    })
  end

  def put_agent(agent, metadata \\ %{}), do: write(:neuron_agent, agent, metadata)
  def put_operation(operation, metadata \\ %{}), do: write(:neuron_operation, operation, metadata)
  def put_outbox(entry, metadata \\ %{}), do: write(:neuron_outbox, entry, metadata)

  def update_outbox(id, status, attempts \\ nil) do
    transaction(
      fn ->
        case :mnesia.read(:neuron_outbox, id) do
          [{:neuron_outbox, ^id, run_id, kind, payload, _old_status, old_attempts, _updated}] ->
            :mnesia.write(
              {:neuron_outbox, id, run_id, kind, payload, status, attempts || old_attempts,
               DateTime.utc_now()}
            )

            :ok

          [] ->
            :not_found
        end
      end,
      %{task_id: "outbox:update", operation_id: id}
    )
  end

  def next_event(run_id, type, payload) do
    transaction(
      fn ->
        sequence =
          :mnesia.foldl(
            fn record, max -> Kernel.max(max, elem(record, 3)) end,
            0,
            :neuron_event
          )

        event =
          {:neuron_event, {run_id, sequence + 1}, run_id, sequence + 1, type, payload,
           DateTime.utc_now()}

        :mnesia.write(event)
        event
      end,
      %{run_id: run_id, task_id: "event:#{type}"}
    )
  end

  def events(run_id) do
    transaction(
      fn ->
        :mnesia.match_object({:neuron_event, :_, run_id, :_, :_, :_, :_})
        |> Enum.sort_by(&elem(&1, 3))
      end,
      %{run_id: run_id, task_id: "events:read"}
    )
  end

  def pending_outbox do
    transaction(
      fn ->
        :mnesia.match_object({:neuron_outbox, :_, :_, :_, :pending, :_, :_})
      end,
      %{task_id: "outbox:pending"}
    )
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:neuron, :storage, [])
    data_dir = config[:data_dir] || "priv/neuron_data"
    File.mkdir_p!(data_dir)
    Application.put_env(:mnesia, :dir, String.to_charlist(data_dir))

    with :ok <- ensure_schema(),
         :ok <- start_mnesia(),
         :ok <- register_rocksdb(config),
         :ok <- create_tables(config) do
      {:ok, %{backend: config[:backend] || :mnesia}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp ensure_schema do
    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, {_, :already_exists}} -> :ok
      {:error, reason} -> {:error, {:mnesia_schema, reason}}
    end
  end

  defp start_mnesia do
    case :mnesia.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:mnesia_start, reason}}
    end
  end

  defp register_rocksdb(%{backend: :rocksdb}) do
    if Code.ensure_loaded?(:mnesia_rocksdb) do
      case apply(:mnesia_rocksdb, :register, []) do
        {:ok, _} -> :ok
        {:error, {:already_registered, _}} -> :ok
        {:error, reason} -> {:error, {:rocksdb_register, reason}}
      end
    else
      Logger.warning("mnesia_rocksdb is unavailable; using disc_copies")
      :ok
    end
  end

  defp register_rocksdb(_), do: :ok

  defp create_tables(config) do
    copy_key =
      if config[:backend] == :rocksdb and Code.ensure_loaded?(:mnesia_rocksdb),
        do: :rocksdb_copies,
        else: :disc_copies

    result =
      Enum.reduce_while(@tables, :ok, fn {table, attributes}, :ok ->
        opts = [{:attributes, attributes}, {copy_key, [node()]}]

        case :mnesia.create_table(table, opts) do
          {:atomic, :ok} -> {:cont, :ok}
          {:aborted, {:already_exists, ^table}} -> {:cont, :ok}
          {:aborted, reason} -> {:halt, {:error, {:create_table, table, reason}}}
        end
      end)

    with :ok <- result do
      case :mnesia.wait_for_tables(Enum.map(@tables, &elem(&1, 0)), 30_000) do
        :ok -> :ok
        other -> {:error, {:wait_for_tables, other}}
      end
    end
  end

  defp write(_table, record, metadata) do
    db_metadata =
      Map.merge(%{task_id: "db:write", operation_id: inspect(elem(record, 1))}, metadata)

    case transaction(fn -> :mnesia.write(record) end, db_metadata) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp read(table, key, metadata) do
    db_metadata = Map.merge(%{task_id: "db:read", operation_id: inspect(key)}, metadata)

    case transaction(fn -> :mnesia.read(table, key) end, db_metadata) do
      {:atomic, [record]} -> {:ok, record}
      {:atomic, []} -> :not_found
      {:aborted, reason} -> {:error, reason}
    end
  end
end
