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

    result =
      Map.merge(metadata, %{
        markdown: markdown,
        content_hash: :crypto.hash(:sha256, markdown) |> Base.encode16(case: :lower),
        extraction_version: 1
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
