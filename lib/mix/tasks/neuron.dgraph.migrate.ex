defmodule Mix.Tasks.Neuron.Dgraph.Migrate do
  @shortdoc "Apply Neuron's versioned Dgraph schema"
  @moduledoc """
  Applies the idempotent Neuron Dgraph schema through Dlex.

      mix neuron.dgraph.migrate
      mix neuron.dgraph.migrate --endpoint localhost:9080 --transport grpc
  """

  use Mix.Task

  @switches [endpoint: :string, transport: :string]

  @impl Mix.Task
  def run(args) do
    {options, [], invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown migration options: #{inspect(invalid)}")
    end

    dgraph = Application.get_env(:neuron, :dgraph, []) |> Keyword.put(:enabled, true)

    dgraph =
      case options[:endpoint] do
        nil -> dgraph
        endpoint -> Keyword.put(dgraph, :endpoint, endpoint)
      end

    dgraph =
      case options[:transport] do
        nil -> dgraph
        transport -> Keyword.put(dgraph, :transport, parse_transport(transport))
      end

    Application.put_env(:neuron, :dgraph, dgraph)
    Mix.Task.run("app.start")

    with {:ok, _storage} <- Neuron.Storage.migrate(),
         connection when not is_nil(connection) <- Neuron.Dgraph.connection() do
      apply_pending_migrations(connection)
    else
      nil -> Mix.raise("Dgraph is unavailable at #{inspect(dgraph[:endpoint])}")
      {:error, reason} -> Mix.raise("Dgraph migration preparation failed: #{inspect(reason)}")
    end
  end

  defp apply_pending_migrations(connection) do
    applied = Neuron.Storage.migration_status(:dgraph)

    with records when is_list(records) <- applied do
      applied_versions = Enum.map(records, &elem(&1, 3))

      pending = Neuron.Migrations.pending(:dgraph, applied_versions)

      migrations =
        if pending == [], do: [{Neuron.Graph.Schema.version(), "graph_schema"}], else: pending

      Enum.each(migrations, fn {version, name} ->
        case Neuron.Graph.Schema.apply(connection,
               task_id: "migration:dgraph:v#{version}",
               migration_version: version
             ) do
          {:ok, _} ->
            record_migration(version, name, applied_versions)

          :ok ->
            record_migration(version, name, applied_versions)

          {:error, reason} ->
            Mix.raise("Dgraph schema migration v#{version} failed: #{inspect(reason)}")

          other ->
            Mix.raise("Dgraph schema migration v#{version} failed: #{inspect(other)}")
        end
      end)

      current = Neuron.Graph.Schema.version()
      Mix.shell().info("Dgraph migration complete (v#{current})")
    else
      {:error, reason} -> Mix.raise("Dgraph migration status failed: #{inspect(reason)}")
    end
  end

  defp record_migration(version, name, applied_versions) do
    if version in applied_versions do
      :ok
    else
      case Neuron.Storage.record_migration(:dgraph, version, name) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.raise("Dgraph migration v#{version} could not be recorded: #{inspect(reason)}")
      end
    end
  end

  defp parse_transport("http"), do: :http
  defp parse_transport("grpc"), do: :grpc
  defp parse_transport(value), do: Mix.raise("transport must be http or grpc, got: #{value}")
end
