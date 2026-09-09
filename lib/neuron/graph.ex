defmodule Neuron.Graph do
  @moduledoc "Dgraph boundary for durable domain facts."

  @callback upsert(map(), keyword()) :: :ok | {:error, term()}

  def upsert(facts, opts \\ []) do
    Neuron.Telemetry.span(
      [:graph, :upsert],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:facts, Neuron.Telemetry.summarize(facts)),
      fn -> do_upsert(facts, opts) end
    )
  end

  defp do_upsert(facts, opts) do
    if Code.ensure_loaded?(Dlex) do
      conn =
        Keyword.get(
          opts,
          :connection,
          Application.get_env(:neuron, :dgraph, [])[:connection] || safe_connection()
        )

      if conn do
        payload = %{set: encode_vectors(facts)}

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
    Neuron.Telemetry.span(
      [:graph, :query],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:query, Neuron.Telemetry.summarize(dql)),
      fn -> do_query(dql, variables, opts) end
    )
  end

  defp do_query(dql, variables, opts) do
    with true <- Code.ensure_loaded?(Dlex),
         conn when not is_nil(conn) <-
           Keyword.get(
             opts,
             :connection,
             Application.get_env(:neuron, :dgraph, [])[:connection] || safe_connection()
           ) do
      apply(Dlex, :query, [conn, dql, variables])
    else
      false -> {:error, :dlex_unavailable}
      nil -> {:error, :dgraph_not_configured}
    end
  end

  defp safe_connection do
    if Process.whereis(Neuron.Dgraph), do: Neuron.Dgraph.connection(), else: nil
  end

  defp encode_vectors(value) when is_list(value), do: Enum.map(value, &encode_vectors/1)

  defp encode_vectors(%{"embedding" => embedding} = map) when is_list(embedding) do
    Map.put(map, "embedding", Dlex.Utils.encode_vector(embedding))
    |> encode_vectors()
  end

  defp encode_vectors(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, encode_vectors(value)} end)

  defp encode_vectors(value), do: value
end
