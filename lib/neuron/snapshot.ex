defmodule Neuron.Snapshot do
  @moduledoc "Clean HTML snapshots and convert them into searchable Markdown."

  def from_html(html, metadata \\ %{}) when is_binary(html) do
    cleaned =
      Neuron.Telemetry.span([:snapshot, :clean], %{task_id: "snapshot:clean"}, fn ->
        clean(html)
      end)

    markdown =
      if Code.ensure_loaded?(Htmd) do
        convert_with_htmd(cleaned)
      else
        fallback_markdown(cleaned)
      end

    result =
      Map.merge(metadata, %{
        markdown: markdown,
        content_hash: :crypto.hash(:sha256, markdown) |> Base.encode16(case: :lower),
        extraction_version: 1
      })

    Neuron.Telemetry.emit([:snapshot, :created], %{
      url: metadata[:url] || metadata["url"],
      content_hash: result.content_hash,
      markdown_bytes: byte_size(markdown)
    })

    {:ok, result}
  end

  def clean(html) do
    html
    |> String.replace(~r/<(script|style|noscript|iframe)\b[^>]*>.*?<\/\1>/is, "")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp convert_with_htmd(html) do
    case apply(Htmd, :convert, [html, [skip_tags: ["script", "style", "nav", "footer"]]]) do
      {:ok, value} -> value
      _ -> fallback_markdown(html)
    end
  rescue
    _ -> fallback_markdown(html)
  end

  defp fallback_markdown(html), do: Regex.replace(~r/<[^>]+>/, html, "") |> String.trim()
end
