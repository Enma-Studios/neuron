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

    case Neuron.Dgraph.connection() do
      nil -> Mix.raise("Dgraph is unavailable at #{inspect(dgraph[:endpoint])}")
      connection -> apply_schema(connection)
    end
  end

  defp apply_schema(connection) do
    case Neuron.Graph.Schema.apply(connection, task_id: "migration:dgraph") do
      {:ok, _} -> Mix.shell().info("Dgraph schema migration complete")
      :ok -> Mix.shell().info("Dgraph schema migration complete")
      {:error, reason} -> Mix.raise("Dgraph schema migration failed: #{inspect(reason)}")
      other -> Mix.raise("Dgraph schema migration failed: #{inspect(other)}")
    end
  end

  defp parse_transport("http"), do: :http
  defp parse_transport("grpc"), do: :grpc
  defp parse_transport(value), do: Mix.raise("transport must be http or grpc, got: #{value}")
end
