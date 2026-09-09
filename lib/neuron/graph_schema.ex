defmodule Neuron.Graph.Schema do
  @moduledoc "Versioned Dgraph predicates for the shared knowledge graph."

  @version 1

  def version, do: @version

  def definition do
    """
    type Entity { name domain profile_url description }
    type Source { url title fetched_at content_hash }
    type Snapshot { markdown content_hash extraction_version }
    type Evidence { excerpt confidence observed_at }
    type Assertion { predicate confidence observed_at }
    name: string @index(term, trigram) .
    domain: string @index(exact) .
    profile_url: string @index(exact) .
    description: string @index(fulltext) .
    url: string @index(exact) .
    title: string @index(term) .
    markdown: string @index(fulltext) .
    content_hash: string @index(exact) .
    embedding: float32vector @index(hnsw(metric:"cosine")) .
    body: string @index(fulltext) .
    """
  end

  def apply(connection \\ nil) do
    Neuron.Telemetry.emit([:graph, :schema], %{version: @version})
    conn = connection || Application.get_env(:neuron, :dgraph, [])[:connection]

    if conn && Code.ensure_loaded?(Dlex) do
      case apply(Dlex, :alter, [conn, definition()]) do
        {:ok, _} = ok -> ok
        error -> error
      end
    else
      {:error, :dgraph_not_configured}
    end
  end
end
