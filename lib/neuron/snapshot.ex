defmodule Neuron.Snapshot do
  @moduledoc "Clean HTML snapshots and convert them into searchable Markdown."

  def from_html(html, metadata \\ %{}) when is_binary(html) do
    trace_metadata = Neuron.Telemetry.trace_metadata(metadata)

    cleaned =
      Neuron.Telemetry.span(
        [:snapshot, :clean],
        Map.put(trace_metadata, :task_id, "snapshot:clean"),
        fn -> clean(html) end
      )

    {:ok, markdown} = Htmd.convert(cleaned, skip_tags: ["script", "style", "nav", "footer"])

    from_markdown(markdown, metadata, trace_metadata, 1)
  end

  @doc """
  Wrap Markdown already extracted inside the browser. Interaction-heavy
  sources yield the cleaned main section this way instead of a converted
  whole-document snapshot.
  """
  def from_markdown(markdown, metadata \\ %{}) when is_binary(markdown) do
    from_markdown(markdown, metadata, Neuron.Telemetry.trace_metadata(metadata), 2)
  end

  defp from_markdown(markdown, metadata, trace_metadata, extraction_version) do
    result =
      Map.merge(metadata, %{
        markdown: markdown,
        content_hash: :crypto.hash(:sha256, markdown) |> Base.encode16(case: :lower),
        extraction_version: extraction_version
      })

    Neuron.Telemetry.emit(
      [:snapshot, :created],
      Map.merge(trace_metadata, %{
        url: metadata[:url] || metadata["url"],
        content_hash: result.content_hash,
        markdown_bytes: byte_size(markdown)
      })
    )

    {:ok, result}
  end

  def clean(html) do
    html
    |> String.replace(~r/<(script|style|noscript|iframe)\b[^>]*>.*?<\/\1>/is, "")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
