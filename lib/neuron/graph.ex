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

  @doc "Insert immutable evidence once, preserving its original observation time on replay."
  def insert_once(%{"uid" => identity} = facts, opts \\ []) do
    connection = Keyword.get_lazy(opts, :connection, &Neuron.Dgraph.connection/0)
    {query, payload} = upsert_request(facts)
    ids = facts |> identify() |> blank_ids() |> Enum.uniq() |> Enum.sort()
    variable = "v#{Enum.find_index(ids, &(&1 == identity))}"

    Neuron.Telemetry.span([:graph, :insert_once], Neuron.Telemetry.trace_metadata(opts), fn ->
      case Dlex.mutate(
             connection,
             %{query: query},
             %{set: encode_vectors(payload), cond: "@if(eq(len(#{variable}), 0))"},
             []
           ) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  defp do_upsert(facts, opts) do
    connection = Keyword.get_lazy(opts, :connection, &Neuron.Dgraph.connection/0)
    {query, payload} = upsert_request(facts)

    case Dlex.mutate(connection, %{query: query}, %{set: encode_vectors(payload)}, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build a single Dgraph upsert using stable external identities for all blank nodes."
  def upsert_request(facts) do
    facts = identify(facts)
    ids = blank_ids(facts) |> Enum.uniq() |> Enum.sort()
    variables = ids |> Enum.with_index() |> Map.new(fn {id, index} -> {id, "v#{index}"} end)

    query =
      Enum.map_join(ids, "\n", fn id ->
        "#{variables[id]} as var(func: eq(external_id, #{Jason.encode!(id)}))"
      end)

    {"{\n" <> query <> "\n}", replace_ids(facts, variables)}
  end

  defp identify(values) when is_list(values), do: Enum.map(values, &identify/1)

  defp identify(map) when is_map(map) do
    map =
      if Map.has_key?(map, "dgraph.type") and not Map.has_key?(map, "uid") do
        Map.put(
          map,
          "uid",
          "_:entity-" <>
            Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(map)), case: :lower)
        )
      else
        map
      end

    Map.new(map, fn {key, value} -> {key, identify(value)} end)
  end

  defp identify(value), do: value
  defp blank_ids(values) when is_list(values), do: Enum.flat_map(values, &blank_ids/1)

  defp blank_ids(map) when is_map(map) do
    own =
      case map["uid"] do
        "_:" <> _ = id -> [id]
        _ -> []
      end

    own ++ Enum.flat_map(Map.values(map), &blank_ids/1)
  end

  defp blank_ids(_), do: []

  defp replace_ids(values, variables) when is_list(values),
    do: Enum.map(values, &replace_ids(&1, variables))

  defp replace_ids(map, variables) when is_map(map) do
    map =
      case map["uid"] do
        "_:" <> _ = id ->
          map |> Map.put("uid", "uid(#{Map.fetch!(variables, id)})") |> Map.put("external_id", id)

        _ ->
          map
      end

    Map.new(map, fn {key, value} -> {key, replace_ids(value, variables)} end)
  end

  defp replace_ids(value, _), do: value

  def query(dql, variables \\ %{}, opts \\ []) do
    Neuron.Telemetry.span(
      [:graph, :query],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:query, Neuron.Telemetry.summarize(dql)),
      fn -> do_query(dql, variables, opts) end
    )
  end

  defp do_query(dql, variables, opts) do
    connection = Keyword.get_lazy(opts, :connection, &Neuron.Dgraph.connection/0)
    Dlex.query(connection, dql, variables)
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
