defmodule Neuron.Dgraph do
  @moduledoc "Owns the application's Dlex connection and exposes readiness."

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def connection, do: GenServer.call(__MODULE__, :connection)

  @impl true
  def init(_opts) do
    config = Application.get_env(:neuron, :dgraph, [])

    state =
      if Code.ensure_loaded?(Dlex) and config[:enabled] != false do
        {hostname, port} = endpoint(config)

        dlex_opts = [
          hostname: hostname,
          port: port,
          pool_size: config[:pool_size] || 4,
          transport: config[:transport] || :grpc
        ]

        case apply(Dlex, :start_link, [dlex_opts]) do
          {:ok, pid} ->
            Application.put_env(:neuron, :dgraph, Keyword.put(config, :connection, pid))
            %{connection: pid}

          {:error, reason} ->
            Logger.warning("Dgraph unavailable at startup: #{inspect(reason)}")
            %{connection: nil}
        end
      else
        %{connection: nil}
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:connection, _from, state), do: {:reply, state.connection, state}

  defp endpoint(config) do
    case config[:endpoint] do
      endpoint when is_binary(endpoint) ->
        uri =
          URI.parse(
            if String.contains?(endpoint, "://"), do: endpoint, else: "grpc://" <> endpoint
          )

        {uri.host || "localhost", uri.port || 9080}

      _ ->
        {config[:hostname] || "localhost", config[:port] || 9080}
    end
  end
end
