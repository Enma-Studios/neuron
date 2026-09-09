defmodule Neuron.Search.Harvest do
  @moduledoc """
  Model-side processing of page transcripts into search results.

  Each transcript produced by a page sub-agent is read by the model, which
  picks the URLs worth ingesting as prospect evidence. Every harvested URL
  must literally appear in the transcript, so the model can only select,
  never invent.
  """

  @max_link_lines 200

  @doc """
  Harvest every transcript concurrently. Returns `{results, failures}`:
  results are engine/result-list pairs ready for merge, failures are
  `%{engine, query, reason}` maps for telemetry and the campaign ledger.
  """
  def from_transcripts(transcripts, opts) do
    harvested =
      Neuron.Pipeline.map(
        transcripts,
        fn transcript -> {transcript, harvest(transcript, opts)} end,
        max_concurrency: Keyword.get(opts, :harvest_concurrency, 4)
      )

    Enum.reduce(harvested, {[], []}, fn
      {transcript, {:ok, results}}, {found, failures} ->
        {[{transcript.engine, results} | found], failures}

      {transcript, {:error, reason}}, {found, failures} ->
        Neuron.Telemetry.emit(
          [:search, :harvest_failed],
          Neuron.Telemetry.trace_metadata(opts)
          |> Map.merge(%{engine: inspect(transcript.engine), reason: inspect(reason)})
        )

        {found,
         [
           %{engine: transcript.engine, query: transcript.query, reason: inspect(reason)}
           | failures
         ]}
    end)
  end

  @doc "Read one transcript with the model and validate the selection."
  def harvest(transcript, opts) do
    content =
      if transcript.markdown == "",
        do: transcript.text,
        else: transcript.markdown

    assigns = %{
      engine: engine_label(transcript.engine),
      query: transcript.query,
      seller: Keyword.get(opts, :seller_domain, ""),
      url: transcript.url,
      content: content,
      links: format_links(transcript.links)
    }

    Neuron.Structured.generate(
      "search_harvest.eex",
      assigns,
      &validate(&1, transcript),
      opts
    )
  end

  defp validate(%{"results" => results}, transcript) when is_list(results) do
    allowed = MapSet.new([transcript.url | Enum.map(transcript.links, & &1.href)])

    valid? =
      Enum.all?(results, fn
        %{"title" => title, "url" => url} when is_binary(title) and is_binary(url) ->
          MapSet.member?(allowed, String.trim(url))

        _ ->
          false
      end)

    if valid? do
      normalized =
        Enum.map(results, fn result ->
          %{
            title: String.trim(result["title"]),
            url: String.trim(result["url"]),
            reason: String.trim(result["reason"] || "")
          }
        end)

      {:ok, Enum.uniq_by(normalized, & &1.url)}
    else
      {:error, :results_must_come_from_transcript}
    end
  end

  defp validate(_other, _transcript), do: {:error, :expected_results}

  defp format_links(links) do
    links
    |> Enum.take(@max_link_lines)
    |> Enum.map_join("\n", &"#{&1.label} — #{&1.href}")
  end

  defp engine_label(engine) when is_atom(engine), do: inspect(engine)
  defp engine_label(other), do: to_string(other)
end
