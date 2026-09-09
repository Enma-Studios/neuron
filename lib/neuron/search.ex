defmodule Neuron.Search do
  @moduledoc "Search providers used by the intelligence exploration pipeline."

  def web(query, opts \\ []) do
    provider = Keyword.get(opts, :provider, Neuron.Search.DuckDuckGo)
    provider.search(query, opts)
  end
end

defmodule Neuron.Search.DuckDuckGo do
  @moduledoc "DuckDuckGo HTML search through the Browser Use provider."

  @endpoint "https://html.duckduckgo.com/html/"

  def search(query, opts \\ []) when is_binary(query) do
    url = @endpoint <> "?" <> URI.encode_query(%{"q" => query})

    browser_opts =
      opts |> Keyword.put(:provider, :browser_use) |> Keyword.put(:task_id, "search:duckduckgo")

    Neuron.Telemetry.span(
      [:search, :duckduckgo],
      Neuron.Telemetry.trace_metadata(browser_opts)
      |> Map.put(:query, Neuron.Telemetry.summarize(query)),
      fn ->
        search_duckduckgo(url, query, browser_opts)
      end
    )
  end

  defp search_duckduckgo(url, query, opts) do
    with {:ok, page} <- Neuron.Browser.fetch(url, opts),
         html when is_binary(html) <- page[:html] || page["html"],
         false <- challenged?(html) do
      {:ok, parse(html)}
    else
      true -> fallback_search(url, query, opts, :duckduckgo_challenge)
      nil -> fallback_search(url, query, opts, :search_returned_no_html)
      {:error, reason} -> fallback_search(url, query, opts, reason)
    end
  end

  defp fallback_search(url, query, opts, reason) do
    Neuron.Telemetry.emit(
      [:search, :fallback],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:reason, inspect(reason))
    )

    with {:ok, page} <- Neuron.Browser.Local.fetch(url, opts),
         html when is_binary(html) <- page[:html] || page["html"],
         false <- challenged?(html) do
      {:ok, parse(html)}
    else
      _ -> model_search(query, opts)
    end
  end

  defp model_search(query, opts) do
    provider =
      Keyword.get(opts, :model_provider, Application.fetch_env!(:neuron, :model)[:provider])

    with {:ok, %{"search_result" => results}} <- provider.web_search(query, opts) do
      results
      |> Enum.map(fn result ->
        %{
          title: result["title"] || "",
          url: result["link"] || result["url"] || "",
          snippet: result["content"] || result["snippet"] || ""
        }
      end)
      |> Enum.filter(&String.starts_with?(&1.url, ["https://", "http://"]))
      |> then(&{:ok, &1})
    else
      {:error, fallback_reason} -> {:error, {:search_unavailable, reason: fallback_reason}}
      _ -> {:error, {:search_unavailable, reason: :invalid_model_search_response}}
    end
  end

  def parse(html) when is_binary(html) do
    snippets =
      Regex.scan(~r/<a[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)<\/a>/is, html,
        capture: :all_but_first
      )
      |> Enum.map(fn [snippet] -> text(snippet) end)

    Regex.scan(
      ~r/<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is,
      html,
      capture: :all_but_first
    )
    |> Enum.with_index()
    |> Enum.map(fn {[href, title], index} ->
      %{
        title: text(title),
        url: normalize_url(href),
        snippet: Enum.at(snippets, index, "")
      }
    end)
    |> Enum.reject(&(&1.url == ""))
    |> Enum.uniq_by(& &1.url)
  end

  defp challenged?(html) do
    String.contains?(html, ["anomaly-modal", "challenge-form", "bots use DuckDuckGo"])
  end

  defp normalize_url(href) do
    uri = URI.parse(html_entities(href))

    cond do
      is_binary(uri.query) and is_binary(uri.host) and
          String.contains?(uri.host, "duckduckgo.com") ->
        case URI.decode_query(uri.query)["uddg"] do
          target when is_binary(target) -> URI.decode(target)
          _ -> ""
        end

      String.starts_with?(href, "//") ->
        "https:" <> href

      String.starts_with?(href, "/") ->
        "https://duckduckgo.com" <> href

      true ->
        html_entities(href)
    end
  end

  defp text(value) do
    value = Regex.replace(~r/<[^>]+>/, value, " ")

    value
    |> html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp html_entities(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
