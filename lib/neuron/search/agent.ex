defmodule Neuron.Search.Agent do
  @moduledoc """
  Sub-agent controlling one browser page per planned search.

  The agent navigates the page, settles it, nudges lazy content loose with
  one scroll, and returns a transcript — final URL, title, the main
  section's Markdown and text, and the section's links with labels — for
  the model to process. It is a fleet page adapter: pass it as
  `page_adapter:` to search fleet calls.
  """

  @lazy_settle 800

  def run_page(handle, task, opts) do
    timeout = Keyword.get(opts, :timeout, 45_000)
    page = Neuron.Browser.Fleet.Target.open(handle.session)

    try do
      _ = Pinocchio.Browser.visit(page, task.url)
      Neuron.Browser.Fleet.CDP.wait_ready(page, task.url, timeout)
      trigger_lazy_content(page)

      with {:ok, raw} <- Neuron.Browser.Scripting.extract(page),
           transcript when is_map(transcript) <- normalize(raw, task) do
        Neuron.Telemetry.emit(
          [:search, :agent],
          Neuron.Telemetry.trace_metadata(opts)
          |> Map.merge(%{
            engine: inspect(task.engine),
            query: Neuron.Telemetry.summarize(task.query),
            transcript_bytes: byte_size(transcript.markdown)
          })
        )

        {:ok, transcript}
      else
        {:error, reason} -> {:error, reason}
      end
    after
      Neuron.Browser.Fleet.Target.close(page)
    end
  end

  @doc "Normalize a raw extraction result into a transcript tagged with its search."
  def normalize(raw, task) when is_map(raw) do
    %{
      url: String.trim(raw["url"] || task.url),
      title: String.trim(raw["title"] || ""),
      markdown: normalize_content(raw["markdown"]),
      text: normalize_content(raw["text"]),
      links: normalize_links(raw["links"]),
      engine: task.engine,
      query: task.query
    }
  end

  def normalize(_raw, _task), do: {:error, :invalid_transcript}

  defp trigger_lazy_content(page) do
    _ =
      Pinocchio.Browser.execute_script(
        page,
        "window.scrollTo(0, Math.max(1, document.body.scrollHeight - 1200))"
      )

    Process.sleep(@lazy_settle)
  end

  defp normalize_content(content) when is_binary(content),
    do: content |> String.slice(0, 16_000) |> String.trim()

  defp normalize_content(_), do: ""

  defp normalize_links(links) when is_list(links) do
    links
    |> Stream.map(&normalize_link/1)
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq_by(& &1.href)
    |> Enum.take(400)
  end

  defp normalize_links(_), do: []

  defp normalize_link(%{"href" => href} = link) when is_binary(href) do
    href = String.trim(href)

    if String.starts_with?(href, ["https://", "http://"]) do
      %{href: href, label: String.trim(link["label"] || "")}
    end
  end

  defp normalize_link(_), do: nil
end
