defmodule Neuron.Search.Google do
  @moduledoc "Google search rendered in a browser page."
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

    fallback =
      ~r/<a[^>]*href=["'](https?:\/\/[^"']+)["'][^>]*>(.*?)<\/a>/is
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [href, title] ->
        %{title: text(title), url: normalize_url(href), snippet: ""}
      end)

    (organic ++ fallback)
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
  @moduledoc "Reddit search rendered from the server-side old Reddit HTML."
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
