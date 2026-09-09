defmodule Neuron.Graph do
  @moduledoc "Dgraph boundary for durable domain facts."

  @callback upsert(map(), keyword()) :: :ok | {:error, term()}

  def upsert(facts, opts \\ []) do
    Neuron.Telemetry.span([:graph, :upsert], Neuron.Telemetry.trace_metadata(opts) |> Map.put(:facts, Neuron.Telemetry.summarize(facts)), fn -> do_upsert(facts, opts) end)
  end

  defp do_upsert(facts, opts) do
    if Code.ensure_loaded?(Dlex) do
      conn = Keyword.get(opts, :connection, Application.get_env(:neuron, :dgraph, [])[:connection])

      if conn do
        payload = %{"set" => facts}

        case apply(Dlex, :mutate, [conn, payload, [return_json: true]]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
      else
        {:error, :dgraph_not_configured}
      end
    else
      {:error, :dlex_unavailable}
    end
  end

  def query(dql, variables \\ %{}, opts \\ []) do
    Neuron.Telemetry.span([:graph, :query], Neuron.Telemetry.trace_metadata(opts) |> Map.put(:query, Neuron.Telemetry.summarize(dql)), fn -> do_query(dql, variables, opts) end)
  end

  defp do_query(dql, variables, opts) do
    with true <- Code.ensure_loaded?(Dlex),
         conn when not is_nil(conn) <- Keyword.get(opts, :connection, Application.get_env(:neuron, :dgraph, [])[:connection]) do
      apply(Dlex, :query, [conn, dql, variables])
    else
      false -> {:error, :dlex_unavailable}
      nil -> {:error, :dgraph_not_configured}
    end
  end
end
