defmodule Mix.Tasks.Neuron.Mnesia.Migrate do
  @shortdoc "Initialize or upgrade Neuron's Mnesia tables"
  @moduledoc """
  Creates the durable Mnesia schema used for run state, operations, events,
  and the publication outbox. Existing tables and records are preserved.

      mix neuron.mnesia.migrate
      mix neuron.mnesia.migrate --data-dir data/neuron --backend rocksdb
  """

  use Mix.Task

  @switches [data_dir: :string, backend: :string]

  @impl Mix.Task
  def run(args) do
    {options, [], invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown migration options: #{inspect(invalid)}")
    end

    configure_storage(options)
    Mix.Task.run("app.start")

    case Neuron.Storage.migrate() do
      {:ok, %{backend: backend, tables: tables, version: version}} ->
        Mix.shell().info(
          "Mnesia migration complete (v#{version}, #{backend}): #{Enum.join(tables, ", ")}"
        )

      {:error, reason} ->
        Mix.raise("Mnesia migration failed: #{inspect(reason)}")
    end
  end

  defp configure_storage(options) do
    storage = Application.get_env(:neuron, :storage, [])

    storage =
      case options[:data_dir] do
        nil -> storage
        data_dir -> Keyword.put(storage, :data_dir, data_dir)
      end

    storage =
      case options[:backend] do
        nil -> storage
        "mnesia" -> Keyword.put(storage, :backend, :mnesia)
        "rocksdb" -> Keyword.put(storage, :backend, :rocksdb)
        backend -> Mix.raise("backend must be mnesia or rocksdb, got: #{backend}")
      end

    Application.put_env(:neuron, :storage, storage)

    if data_dir = storage[:data_dir] do
      Application.put_env(:mnesia, :dir, String.to_charlist(data_dir))
    end
  end
end
