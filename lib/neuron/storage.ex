defmodule Neuron.Storage do
  @moduledoc """
  Durable execution storage.

  Agent execution state lives in Mnesia. The default configuration requires
  `mnesia_rocksdb` and uses its `rocksdb_copies` backend. Domain facts are
  written synchronously to Dgraph by the research workflows.
  """

  use GenServer
  @compile {:no_warn_undefined, :mnesia}

  @tables [
    {:neuron_run, [:id, :profile, :input, :status, :inserted_at, :updated_at, :result, :error]},
    {:neuron_agent, [:id, :run_id, :parent_id, :role, :status, :state, :updated_at]},
    {:neuron_operation,
     [:id, :run_id, :agent_id, :kind, :attempt, :status, :request, :response, :updated_at]},
    {:neuron_event, [:key, :run_id, :sequence, :type, :payload, :inserted_at]},
    {:neuron_migration, [:id, :backend, :version, :name, :applied_at]}
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

  def next_event(run_id, type, payload, metadata \\ %{}) do
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
      Map.merge(%{run_id: run_id, task_id: "event:#{type}"}, metadata)
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

  @doc "Return applied migration records, optionally filtered by backend."
  def migration_status(backend \\ nil) do
    result =
      transaction(
        fn ->
          :mnesia.match_object({:neuron_migration, :_, :_, :_, :_, :_})
          |> Enum.filter(fn {:neuron_migration, _id, record_backend, _version, _name, _at} ->
            is_nil(backend) or record_backend == backend
          end)
          |> Enum.sort_by(&elem(&1, 3))
        end,
        %{task_id: "db:migrations:read"}
      )

    case result do
      {:atomic, records} -> records
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Record a migration version after its changes have been applied."
  def record_migration(backend, version, name) do
    id = "#{backend}:#{version}"

    case transaction(
           fn ->
             :mnesia.write({:neuron_migration, id, backend, version, name, DateTime.utc_now()})

             :ok
           end,
           %{task_id: "db:migrations:write", operation_id: id, migration_version: version}
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensure the durable Mnesia schema and Neuron tables exist.

  This operation is idempotent and is safe to run from a release or a Mix
  task while the application is already started.
  """
  def migrate do
    config = Application.get_env(:neuron, :storage, [])

    with :ok <- ensure_disc_schema(),
         :ok <- register_rocksdb(config),
         :ok <- create_tables(config),
         {:ok, applied} <- apply_pending_migrations(:mnesia) do
      {:ok,
       %{
         backend: config[:backend] || :mnesia,
         tables: Enum.map(@tables, &elem(&1, 0)),
         version: max_version(applied),
         migrations: applied
       }}
    end
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:neuron, :storage, [])
    data_dir = config[:data_dir] || "priv/neuron_data"
    File.mkdir_p!(data_dir)
    Application.put_env(:mnesia, :dir, String.to_charlist(data_dir))

    with :ok <- ensure_schema(),
         :ok <- start_mnesia(),
         :ok <- ensure_disc_schema(),
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

  defp ensure_disc_schema do
    case :mnesia.table_info(:schema, :storage_type) do
      :disc_copies ->
        :ok

      :ram_copies ->
        current_node = node()

        case :mnesia.change_table_copy_type(:schema, current_node, :disc_copies) do
          {:atomic, :ok} -> :ok
          {:aborted, {:already_exists, :schema, ^current_node, :disc_copies}} -> :ok
          {:aborted, reason} -> {:error, {:mnesia_schema_storage, reason}}
        end

      other ->
        {:error, {:mnesia_schema_storage, other}}
    end
  end

  defp register_rocksdb(config) when is_list(config) do
    if config[:backend] == :rocksdb do
      if Code.ensure_loaded?(:mnesia_rocksdb) do
        register_rocksdb_backend()
      else
        {:error, :mnesia_rocksdb_unavailable}
      end
    else
      :ok
    end
  end

  defp register_rocksdb(_), do: :ok

  defp register_rocksdb_backend do
    case apply(:mnesia_rocksdb, :register, []) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> {:error, {:rocksdb_register, reason}}
    end
  end

  defp create_tables(config) do
    copy_key =
      if config[:backend] == :rocksdb, do: :rocksdb_copies, else: :disc_copies

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

  defp apply_pending_migrations(backend) do
    with applied_records when is_list(applied_records) <- migration_status(backend) do
      applied_versions = Enum.map(applied_records, &elem(&1, 3))

      Enum.reduce_while(
        Neuron.Migrations.pending(backend, applied_versions),
        {:ok, applied_records},
        fn
          {version, name}, {:ok, records} ->
            case record_migration(backend, version, name) do
              :ok ->
                record =
                  {:neuron_migration, "#{backend}:#{version}", backend, version, name,
                   DateTime.utc_now()}

                {:cont, {:ok, [record | records]}}

              {:error, reason} ->
                {:halt, {:error, {:migration, backend, version, reason}}}
            end
        end
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp max_version([]), do: 0
  defp max_version(records), do: Enum.max(Enum.map(records, &elem(&1, 3)))

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
