defmodule Neuron.Search.Google do
  @moduledoc """
  Google search rendered in a browser page.

  Available but switched off by default: from Browser Use cloud addresses
  every query redirects to the `/sorry/` bot check, measured seven times
  out of seven in one run and four out of four in another, so the engine
  contributes nothing and is reported as a skipped engine on every query.
  Re-enable it through `:neuron, :search, :engines` from an address it
  serves results to, which a local browser provider may be (`neuron-02`).
  """
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [html_entities: 1, text: 1]

  @endpoint "https://www.google.com/search"

  @impl true
  def kind, do: :web

  @impl true
  def keywords(query), do: query

  @impl true
  def search_url(keywords),
    do: @endpoint <> "?" <> URI.encode_query(%{"q" => keywords, "num" => "20"})

  @impl true
  def parse(html) when is_binary(html) do
    ~r/<a[^>]*href=["'](\/url\?q=[^"']+|https?:\/\/[^"']+)["'][^>]*>(.*?)<\/a>/is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [href, title] ->
      %{title: text(title), url: normalize_url(href), snippet: ""}
    end)
    |> Enum.reject(&(&1.url == "" or &1.title == ""))
    |> Enum.uniq_by(& &1.url)
  end

  @impl true
  def blocked?(html) do
    String.contains?(html, ["unusual traffic", "/sorry/", "g-recaptcha"])
  end

  @impl true
  def gated?(_html), do: false

  defp normalize_url("/url?" <> query) do
    case URI.decode_query(query) do
      %{"q" => target} when is_binary(target) -> clean(target)
      _ -> ""
    end
  end

  defp normalize_url(href), do: clean(href)

  defp clean(href) do
    uri = URI.parse(html_entities(href))
    host = String.downcase(uri.host || "")

    if uri.scheme in ["http", "https"] and host != "" and not internal_host?(host),
      do: URI.to_string(uri),
      else: ""
  end

  defp internal_host?(host) do
    host == "google.com" or String.ends_with?(host, ".google.com") or
      String.ends_with?(host, ".gstatic.com") or String.ends_with?(host, ".googleusercontent.com")
  end
end

defmodule Neuron.Search.Yandex do
  @moduledoc "Yandex search rendered in a browser page."
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [html_entities: 1, text: 1]

  @endpoint "https://yandex.com/search/"

  @impl true
  def kind, do: :web

  @impl true
  def keywords(query), do: query

  @impl true
  def search_url(keywords),
    do: @endpoint <> "?" <> URI.encode_query(%{"text" => keywords})

  @impl true
  def parse(html) when is_binary(html) do
    organic =
      ~r/<a[^>]*class=["'][^"']*organic__url[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [href, title] ->
        %{title: text(title), url: normalize_url(href), snippet: ""}
      end)

    external =
      ~r/<a[^>]*href=["'](https?:\/\/[^"']+)["'][^>]*>(.*?)<\/a>/is
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [href, title] ->
        %{title: text(title), url: normalize_url(href), snippet: ""}
      end)

    (organic ++ external)
    |> Enum.reject(&(&1.url == "" or &1.title == ""))
    |> Enum.uniq_by(& &1.url)
  end

  @impl true
  def blocked?(html) do
    String.contains?(html, ["show-captcha", "SmartCaptcha", "captcha-block"])
  end

  @impl true
  def gated?(_html), do: false

  defp normalize_url(href) do
    uri = URI.parse(html_entities(href))
    host = String.downcase(uri.host || "")

    if uri.scheme in ["http", "https"] and host != "" and not internal_host?(host),
      do: URI.to_string(uri),
      else: ""
  end

  defp internal_host?(host) do
    host == "yandex.com" or host == "yandex.ru" or String.ends_with?(host, ".yandex.com") or
      String.ends_with?(host, ".yandex.ru") or String.ends_with?(host, ".yandex.net") or
      String.ends_with?(host, ".yastatic.net")
  end
end

defmodule Neuron.Search.LinkedIn do
  @moduledoc "Native LinkedIn search rendered in a logged-in browser page."
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [html_entities: 1, strip_site_operators: 1, text: 1]

  @endpoint "https://www.linkedin.com/search/results/all/"

  @impl true
  def kind, do: :social

  @impl true
  def keywords(query), do: strip_site_operators(query)

  @impl true
  def search_url(keywords),
    do: @endpoint <> "?" <> URI.encode_query(%{"keywords" => keywords})

  @impl true
  def parse(html) when is_binary(html) do
    ~r/<a[^>]*href=["']([^"']*(?:\/in\/|\/company\/|\/school\/|\/pub\/)[^"']*)["'][^>]*>(.*?)<\/a>/is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [href, title] ->
      %{title: text(title), url: normalize_url(href), snippet: ""}
    end)
    |> Enum.reject(&(&1.url == "" or &1.title == ""))
    |> Enum.uniq_by(& &1.url)
  end

  @impl true
  def blocked?(_html), do: false

  @impl true
  def gated?(html) do
    String.contains?(html, ["authwall", "Sign in to continue", "session_redirect"])
  end

  defp normalize_url(href) do
    uri = URI.parse(html_entities(href))

    cond do
      is_binary(uri.host) and String.contains?(String.downcase(uri.host), "linkedin.com") ->
        profile_url(uri.path)

      String.starts_with?(uri.path || "", "/") ->
        profile_url(uri.path)

      true ->
        ""
    end
  end

  defp profile_url(path) when is_binary(path) and path != "/" do
    if String.contains?(path, ["/in/", "/company/", "/school/", "/pub/"]),
      do: "https://www.linkedin.com" <> path,
      else: ""
  end

  defp profile_url(_), do: ""
end

defmodule Neuron.Search.X do
  @moduledoc "Native X people search rendered in a logged-in browser page."
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [strip_site_operators: 1, text: 1]

  @endpoint "https://x.com/search"

  @reserved ~w(home explore i notifications messages bookmarks lists profile settings search
               login signup intent compose post hashtag analytics ads guard)

  @impl true
  def kind, do: :social

  @impl true
  def keywords(query), do: strip_site_operators(query)

  @impl true
  def search_url(keywords) do
    @endpoint <>
      "?" <>
      URI.encode_query(%{"q" => keywords, "src" => "typed_query", "f" => "user"})
  end

  @impl true
  def parse(html) when is_binary(html) do
    ~r/<a[^>]*href=["']\/([A-Za-z0-9_]{1,15})["'][^>]*>(.*?)<\/a>/is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [handle, inner] -> %{handle: handle, title: text(inner)} end)
    |> Enum.reject(&(&1.title == "" or &1.handle in @reserved))
    |> Enum.uniq_by(& &1.handle)
    |> Enum.map(fn entry ->
      %{title: entry.title, url: "https://x.com/" <> entry.handle, snippet: ""}
    end)
  end

  @impl true
  def blocked?(_html), do: false

  @impl true
  def gated?(html) do
    String.contains?(html, ["Sign in to X", "/account/access", "login?redirect_after_login"])
  end
end

defmodule Neuron.Search.Reddit do
  @moduledoc """
  Reddit search rendered from the server-side old Reddit HTML.

  Disabled by default: cloud datacenter IPs are redirected to a login wall.
  Re-enable through `:neuron, :search, :engines` once searches run through
  residential proxies.
  """
  @behaviour Neuron.Search.Engine

  import Neuron.Search.Engine, only: [html_entities: 1, strip_site_operators: 1, text: 1]

  @endpoint "https://old.reddit.com/search/"

  @impl true
  def kind, do: :social

  @impl true
  def keywords(query), do: strip_site_operators(query)

  @impl true
  def search_url(keywords),
    do: @endpoint <> "?" <> URI.encode_query(%{"q" => keywords, "sort" => "relevance"})

  @impl true
  def parse(html) when is_binary(html) do
    ~r/<a[^>]*class=["'][^"']*search-title[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [href, title] ->
      %{title: text(title), url: normalize_url(href), snippet: ""}
    end)
    |> Enum.reject(&(&1.url == ""))
    |> Enum.uniq_by(& &1.url)
  end

  @impl true
  def blocked?(html) do
    String.contains?(html, ["whoa there", "you broke reddit"])
  end

  @impl true
  def gated?(_html), do: false

  defp normalize_url(href) do
    uri = URI.parse(html_entities(href))
    host = String.downcase(uri.host || "")

    if uri.scheme in ["http", "https"] and host != "",
      do: URI.to_string(uri),
      else: ""
  end
end

defmodule Neuron.Search.Brave do
  @moduledoc """
  Brave Search API: a keyed engine that needs no browser.

  Bot checks from cloud addresses had reduced public discovery to Yandex
  alone. Google redirects every query to its `/sorry/` interstitial and
  DuckDuckGo serves its anomaly modal intermittently, both measured, and
  neither is something to work around. An API answers with a key instead
  of with a page, so there is no wall to be stopped by and no browser
  session to bill.

  Enabled only when `BRAVE_SEARCH_API_KEY` is set, or `:neuron, :search,
  :brave, :api_key` is configured. Without a key the engine is absent from
  the round rather than failing in it: nobody asked it, so it cannot be
  evidence that search is unavailable.
  """
  @behaviour Neuron.Search.Engine

  @endpoint "https://api.search.brave.com/res/v1/web/search"
  @count 20

  @impl true
  def kind, do: :web

  @impl true
  def keywords(query), do: query

  @impl true
  def search_url(keywords),
    do: @endpoint <> "?" <> URI.encode_query(%{"q" => keywords, "count" => @count})

  @impl true
  def available?, do: is_binary(api_key()) and api_key() != ""

  @doc "The configured key, from application config first and the environment second."
  def api_key do
    Application.get_env(:neuron, :search, [])[:brave][:api_key] ||
      System.get_env("BRAVE_SEARCH_API_KEY")
  end

  @impl true
  def transcript(task, opts) do
    with {:ok, body} <- get(task.url, opts), do: {:ok, build_transcript(task, body)}
  end

  @doc """
  Build the transcript a browser page would have produced, from an API
  response body.

  The same shape `Neuron.Search.Agent` returns, so the wall check, the
  harvest and its exact-URL contract all work unchanged: every URL the
  model may select is in `links`, and nothing else is.
  """
  def build_transcript(task, body) do
    results = parse(body)

    %{
      url: task.url,
      title: "Brave Search results for #{task.query}",
      markdown: Enum.map_join(results, "\n", &"- [#{&1.title}](#{&1.url})\n  #{&1.snippet}"),
      text: Enum.map_join(results, "\n", &"#{&1.title}. #{&1.snippet}"),
      # A keyed API returns no document, and there is no wall to read out of
      # one. An empty document is what `wall_reason/1` expects to see here.
      document: "",
      links: Enum.map(results, &%{href: &1.url, label: &1.title}),
      engine: __MODULE__,
      query: task.query
    }
  end

  @impl true
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _} -> []
    end
  end

  def parse(%{"web" => %{"results" => results}}) when is_list(results) do
    for result <- results,
        url = result["url"],
        is_binary(url) and String.starts_with?(url, ["http://", "https://"]) do
      %{
        title: Neuron.Search.Engine.text(result["title"] || ""),
        url: url,
        snippet: Neuron.Search.Engine.text(result["description"] || "")
      }
    end
    |> Enum.uniq_by(& &1.url)
  end

  def parse(_body), do: []

  # A keyed API is not bot-checked and does not gate. A key that is refused
  # or exhausted comes back as an error from the request, which is an engine
  # failure with its own reason, not a wall in a page.
  @impl true
  def blocked?(_body), do: false

  @impl true
  def gated?(_body), do: false

  defp get(url, opts) do
    headers = [{"x-subscription-token", api_key()}, {"accept", "application/json"}]

    case apply(Req, :get, [
           url,
           [headers: headers, receive_timeout: Keyword.get(opts, :brave_timeout, 15_000)]
         ]) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :brave_key_refused}
      {:ok, %{status: 429}} -> {:error, :brave_rate_limited}
      {:ok, %{status: status, body: body}} -> {:error, {:brave_http, status, body}}
      {:error, reason} -> {:error, {:brave_transport, reason}}
    end
  end
end
