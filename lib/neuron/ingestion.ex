defmodule Neuron.Ingestion do
  @moduledoc "Durable document ingestion, independent of campaigns. Supply a URL or a validated Markdown document."
  @behaviour Neuron.Coordinator
  def submit(source, opts \\ []), do: Neuron.start_run(__MODULE__, source, opts)
  def get(id), do: Neuron.get_run(id)
  def plan(source, _context), do: {:ok, %{source: source}}
  def run(_plan, _context), do: raise("ingestion executes as checkpointed stages")
  def stages, do: [:fetch, :evidence, :normalize, :reconcile, :index]

  def stage(:fetch, %{source: %{markdown: _} = attrs} = data, _opts) do
    with {:ok, document} <- Neuron.Contracts.validate(Neuron.Contracts.Document, attrs),
         do: {:ok, Map.put(data, :document, document)}
  end

  def stage(:fetch, data, opts) do
    url = Neuron.Knowledge.canonical_url(Map.fetch!(data.source, :url))

    opts = Keyword.put(opts, :section_extract, Neuron.Browser.Scripting.rich_host?(url))

    with {:ok, page} <- Neuron.Browser.fetch(url, opts),
         {:ok, snapshot} <- snapshot(page, url),
         {:ok, document} <-
           Neuron.Contracts.validate(Neuron.Contracts.Document, %{
             url: url,
             title: page[:title] || "",
             markdown: snapshot.markdown,
             provider: to_string(page[:provider]),
             fetched_at: DateTime.utc_now()
           }) do
      {:ok, Map.put(data, :document, document)}
    end
  end

  def stage(:evidence, data, opts) do
    with {:ok, id} <- Neuron.Knowledge.save_document(data.document, opts),
         do: {:ok, Map.put(data, :snapshot_id, id)}
  end

  def stage(:normalize, data, opts) do
    size = Keyword.get(opts, :prompt_characters, 24000)
    true = size > 256

    results =
      data.document.markdown
      |> String.graphemes()
      |> Enum.chunk_every(size, size - 256)
      |> Neuron.Pipeline.map(
        fn chars ->
          Neuron.Structured.generate(
            "normalize_source.eex",
            %{url: data.document.url, markdown: Enum.join(chars)},
            &Neuron.Knowledge.validate_claims(&1, data.document),
            opts
          )
        end,
        max_concurrency: Keyword.get(opts, :normalization_concurrency, 2)
      )

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {claims, signals} =
          results
          |> Enum.flat_map(fn {:ok, claims} -> claims end)
          |> Enum.uniq()
          |> Neuron.Knowledge.role_signals(data.document)

        {:ok, data |> Map.put(:claims, claims) |> Map.put(:role_signals, signals)}

      error ->
        error
    end
  end

  def stage(:reconcile, data, opts) do
    with :ok <- Neuron.Knowledge.ingest(data.claims, data.document, data.snapshot_id, opts),
         do: {:ok, data}
  end

  def stage(:index, data, opts) do
    with :ok <- Neuron.Knowledge.index_document(data.document, data.snapshot_id, opts),
         do:
           {:ok,
            %{
              source_url: data.document.url,
              snapshot_id: data.snapshot_id,
              claim_count: length(data.claims),
              # What a campaign's people-page step judges a page by.
              named_people: Neuron.Knowledge.named_people(data.claims),
              people_links: Neuron.PeoplePages.links(data.document.url, data.document.markdown),
              role_signals: Map.get(data, :role_signals, [])
            }}
  end

  # Interaction-heavy pages carry Markdown extracted from their main
  # section in the browser; everything else converts the whole document.
  defp snapshot(%{markdown: markdown}, url) when is_binary(markdown) and markdown != "",
    do: Neuron.Snapshot.from_markdown(markdown, %{url: url})

  defp snapshot(page, url),
    do: Neuron.Snapshot.from_html(Map.fetch!(page, :html), %{url: url})
end
