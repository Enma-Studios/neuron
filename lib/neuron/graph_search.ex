defmodule Neuron.GraphSearch do
  @moduledoc "Search facade; Dgraph owns domain indexes and vectors."

  def lexical(query, opts \\ []) do
    dql =
      "query search($q: string) { results(func: anyoftext(body, $q), first: 25) { uid body source_url } }"

    Neuron.Graph.query(dql, %{"$q" => query}, opts)
  end

  def profiles(query, opts \\ []) do
    dql =
      """
      query profiles($q: string) {
        organizations(func: anyoftext(description, $q), first: 25) { uid name domain industry geographies people clients }
        people(func: anyoftext(bio, $q), first: 25) { uid name title employer location social_accounts posts }
        requirements(func: anyoftext(description, $q), first: 25) { uid category description required_by applies_to }
        posts(func: anyoftext(body, $q), first: 25) { uid title url author organization published_at embedding }
      }
      """

    Neuron.Graph.query(dql, %{"$q" => query}, opts)
  end

  def fit_profiles(query, opts \\ []) do
    dql =
      "query fit_profiles($q: string) { results(func: anyoftext(description, $q), first: 25) @filter(type(FitProfile)) { uid name description campaign target_organizations target_people required_capabilities preferred_geographies } }"

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

  def fuse(left, right) do
    [left["results"] || [], right["results"] || []]
    |> Enum.flat_map(fn rows -> Enum.with_index(rows, 1) end)
    |> Enum.reduce(%{}, fn {row, rank}, acc ->
      Map.update(acc, row["uid"], Map.put(row, "rrf_score", 1 / (60 + rank)), fn existing ->
        Map.update!(existing, "rrf_score", &(&1 + 1 / (60 + rank)))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{-&1["rrf_score"], &1["uid"]})
  end
end
