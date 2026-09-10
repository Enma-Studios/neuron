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
      case with_conflict_retry(opts, fn ->
             Dlex.mutate(
               connection,
               %{query: query},
               %{set: encode_vectors(payload), cond: "@if(eq(len(#{variable}), 0))"},
               []
             )
           end) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  @doc "Replace current projection predicates while preserving assertion and document history."
  def replace(facts, predicates, opts \\ []) do
    connection = Keyword.get_lazy(opts, :connection, &Neuron.Dgraph.connection/0)
    {query, payload} = upsert_request(facts)
    deletion = Map.new(predicates, &{&1, nil}) |> Map.put("uid", payload["uid"])

    Neuron.Telemetry.span([:graph, :replace], Neuron.Telemetry.trace_metadata(opts), fn ->
      case with_conflict_retry(opts, fn ->
             Dlex.mutate(
               connection,
               %{query: query},
               %{delete: deletion, set: encode_vectors(payload)},
               []
             )
           end) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  defp do_upsert(facts, opts) do
    connection = Keyword.get_lazy(opts, :connection, &Neuron.Dgraph.connection/0)
    {query, payload} = upsert_request(facts)

    result =
      with_conflict_retry(opts, fn ->
        Dlex.mutate(connection, %{query: query}, %{set: encode_vectors(payload)}, [])
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @conflict_attempts 5
  @conflict_backoff_ms 50
  @conflict_backoff_cap_ms 800

  @doc """
  Run a graph mutation, retrying while Dgraph aborts the transaction.

  A gRPC `ABORTED` is the database saying two writers touched the same
  entity concurrently and the loser should try again. It is not a statement
  that the write was wrong. Neuron dispatches a batch of ingestion children
  at once and they routinely upsert overlapping organizations, sources and
  claims, so the collision is expected rather than exceptional, and the
  message says "Please retry" where nothing used to.

  Backoff is exponential with jitter and a cap, and the attempt count is
  bounded: a genuinely contended entity must eventually give up rather than
  hold a stage open. Any error that is not an abort is returned on the
  first attempt, unchanged. A conflict that exhausts its retries is counted
  against the run, so a run that lost evidence says so.
  """
  def with_conflict_retry(opts, fun) when is_function(fun, 0) do
    attempt_mutation(opts, fun, 1)
  end

  defp attempt_mutation(opts, fun, attempt) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        attempts = Keyword.get(opts, :graph_conflict_attempts, @conflict_attempts)

        cond do
          not conflict?(reason) ->
            error

          attempt < attempts ->
            Neuron.Telemetry.emit(
              [:graph, :conflict_retry],
              Neuron.Telemetry.trace_metadata(opts)
              |> Map.merge(%{attempt: attempt, attempts: attempts})
            )

            Process.sleep(backoff(attempt, opts))
            attempt_mutation(opts, fun, attempt + 1)

          true ->
            Neuron.Telemetry.emit(
              [:graph, :conflict_exhausted],
              Neuron.Telemetry.trace_metadata(opts) |> Map.put(:attempts, attempts)
            )

            :ok = Neuron.Usage.record_conflict(opts)
            error
        end
    end
  end

  @doc "Whether a Dgraph error is a transaction abort, which is worth retrying."
  # Matched structurally where the shape is known and by Dgraph's own wording
  # otherwise, so a change in the client's error struct cannot silently turn
  # every abort into a permanent failure again.
  def conflict?(%{reason: %{status: 10}}), do: true
  def conflict?(%{status: 10}), do: true
  def conflict?(reason) when is_binary(reason), do: aborted?(reason)
  def conflict?(reason), do: aborted?(inspect(reason))

  defp aborted?(text), do: String.contains?(text, "Transaction has been aborted")

  defp backoff(attempt, opts) do
    base = Keyword.get(opts, :graph_conflict_backoff_ms, @conflict_backoff_ms)

    case base * Integer.pow(2, attempt - 1) do
      0 -> 0
      delay -> min(delay, @conflict_backoff_cap_ms) + :rand.uniform(base + 1) - 1
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

    query = if ids == [], do: "", else: "{\n" <> query <> "\n}"
    {query, replace_ids(facts, variables)}
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

  defp encode_vectors(map) when is_map(map),
    do:
      Map.new(map, fn
        {"embedding_e5_384", value} when is_list(value) ->
          {"embedding_e5_384", Dlex.Utils.encode_vector(value)}

        {key, value} ->
          {key, encode_vectors(value)}
      end)

  defp encode_vectors(value), do: value
end
