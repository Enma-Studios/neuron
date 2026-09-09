defmodule Neuron.Graph.Schema do
  @moduledoc "Versioned Dgraph predicates for the shared knowledge graph."

  @version 1

  def version, do: @version

  def definition do
    """
    type Entity {
      name: string
      domain: string
      profile_url: string
      description: string
    }
    type Source {
      url: string
      title: string
      fetched_at: datetime
      content_hash: string
    }
    type Snapshot {
      markdown: string
      content_hash: string
      extraction_version: int
    }
    type Evidence {
      excerpt: string
      confidence: float
      observed_at: datetime
    }
    type Assertion {
      predicate: string
      confidence: float
      observed_at: datetime
    }
    name: string @index(term, trigram) .
    domain: string @index(exact) .
    profile_url: string @index(exact) .
    description: string @index(fulltext) .
    url: string @index(exact) .
    title: string @index(term) .
    fetched_at: datetime .
    markdown: string @index(fulltext) .
    content_hash: string @index(exact) .
    extraction_version: int .
    excerpt: string @index(fulltext) .
    confidence: float .
    observed_at: datetime .
    predicate: string .
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
