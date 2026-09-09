defmodule Neuron.GraphSearch do
  @moduledoc "Search facade; Dgraph owns domain indexes and vectors."

  def lexical(query, opts \\ []) do
    dql =
      "query search($q: string) { results(func: anyoftext(body, $q), first: 25) { uid body source_url } }"

    Neuron.Graph.query(dql, %{"$q" => query}, opts)
  end

  def semantic(vector, opts \\ []) do
    dql =
      "query search($v: float32vector) { results(func: similar_to(embedding, 25, $v)) { uid body source_url } }"

    Neuron.Graph.query(dql, %{"$v" => vector}, opts)
  end

  def hybrid(query, vector, opts \\ []) do
    Neuron.Telemetry.span([:graph, :hybrid_search], Neuron.Telemetry.trace_metadata(opts), fn ->
      with {:ok, lexical} <- lexical(query, opts), {:ok, semantic} <- semantic(vector, opts) do
        {:ok, fuse(lexical, semantic)}
      end
    end)
  end

  defp fuse(left, right), do: %{lexical: left, semantic: right, strategy: :reciprocal_rank_fusion}
end
