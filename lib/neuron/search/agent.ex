defmodule Neuron.Search.Agent do
  @moduledoc """
  Sub-agent controlling one browser page per planned search.

  The agent navigates the page, settles it, nudges lazy content loose with
  one scroll, and returns a transcript — final URL, title, visible text,
  and the page's links with labels — for the model to process. It is a
  fleet page adapter: pass it as `page_adapter:` to search fleet calls.
  """

  @extraction_script """
  (() => {
    const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 400).map(a => ({
      href: a.href,
      label: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 200)
    }));
    return {
      url: location.href,
      title: document.title,
      text: (document.body ? document.body.innerText : '').slice(0, 16000),
      links: links
    };
  })()
  """

  @max_text 16_000
  @max_links 400
  @lazy_settle 800

  def run_page(handle, task, opts) do
    timeout = Keyword.get(opts, :timeout, 45_000)

    try do
      page = Pinocchio.Browser.new_page(handle.session)

      try do
        _ = Pinocchio.Browser.visit(page, task.url)
        Neuron.Browser.Fleet.CDP.wait_ready(page, task.url, timeout)
        trigger_lazy_content(page)

        with {:ok, %{"result" => %{"value" => value}}} <-
               Pinocchio.Browser.execute_script(page, @extraction_script),
             transcript when is_map(transcript) <- normalize(value, task) do
          Neuron.Telemetry.emit(
            [:search, :agent],
            Neuron.Telemetry.trace_metadata(opts)
            |> Map.merge(%{
              engine: inspect(task.engine),
              query: Neuron.Telemetry.summarize(task.query),
              transcript_bytes: byte_size(transcript.text)
            })
          )

          {:ok, transcript}
        else
          _ -> {:error, :transcript_extraction_failed}
        end
      after
        _ = Pinocchio.Browser.close_page(page)
      end
    rescue
      error -> {:error, {:agent_error, Exception.message(error)}}
    end
  end

  @doc "Normalize a raw extraction result into a transcript tagged with its search."
  def normalize(raw, task) when is_map(raw) do
    %{
      url: String.trim(raw["url"] || task.url),
      title: String.trim(raw["title"] || ""),
      text: normalize_text(raw["text"]),
      links: normalize_links(raw["links"]),
      engine: task.engine,
      query: task.query
    }
  end

  def normalize(_raw, _task), do: {:error, :invalid_transcript}

  @doc "The JavaScript evaluated in the page to collect url, title, text, and links."
  def extraction_script, do: @extraction_script

  defp trigger_lazy_content(page) do
    _ =
      Pinocchio.Browser.execute_script(
        page,
        "window.scrollTo(0, Math.max(1, document.body.scrollHeight - 1200))"
      )

    Process.sleep(@lazy_settle)
  end

  defp normalize_text(text) when is_binary(text),
    do: text |> String.slice(0, @max_text) |> String.trim()

  defp normalize_text(_), do: ""

  defp normalize_links(links) when is_list(links) do
    links
    |> Stream.map(&normalize_link/1)
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq_by(& &1.href)
    |> Enum.take(@max_links)
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
