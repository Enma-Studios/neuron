defmodule Neuron.Browser.Scripting do
  @moduledoc """
  In-page DOM extraction for interaction-heavy sources.

  Whole-document snapshots of SPA pages bury the useful content under
  navigation and chrome, and shipping the full DOM starves the CDP
  connection. The extraction selects the main content section, cleans a
  clone of it, and converts it to Markdown inside the browser with the
  bundled Turndown build, so only a compact section ever leaves the page.
  """

  @default_rich_hosts ~w(linkedin.com x.com twitter.com facebook.com instagram.com reddit.com
                         crunchbase.com wellfound.com)

  @extraction_script """
  (() => {
    const section = document.querySelector('main, [role="main"], [data-testid="primaryColumn"], .search-results__results-list, #content') || document.body;
    const clone = section.cloneNode(true);
    clone.querySelectorAll('script,style,noscript,svg,template,nav,aside,form,button,select').forEach(e => e.remove());
    let markdown = '';
    try {
      if (window.TurndownService) {
        markdown = new window.TurndownService({headingStyle: 'atx', codeBlockStyle: 'fenced'}).turndown(clone);
      }
    } catch (error) {
      markdown = '';
    }
    const links = Array.from(section.querySelectorAll('a[href]')).slice(0, 400).map(a => ({
      href: a.href,
      label: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 200)
    }));
    const source = document.documentElement.outerHTML;
    return {
      url: location.href,
      title: document.title,
      markdown: markdown.slice(0, 16000),
      text: (section.innerText || '').slice(0, 8000),
      document: source.length < 32000 ? source : '',
      links: links
    };
  })()
  """

  @doc "The bundled Turndown source injected before extraction. Cached in memory."
  def turndown_source do
    case :persistent_term.get({__MODULE__, :turndown}, :undefined) do
      :undefined ->
        source = File.read!(Path.join(:code.priv_dir(:neuron), "vendor/turndown.js"))
        :persistent_term.put({__MODULE__, :turndown}, source)
        source

      source ->
        source
    end
  end

  @doc """
  The JavaScript that returns url, title, section markdown, section text,
  links, and the whole document when it is small.

  A bot check, a consent wall and a login page are all tiny compared with a
  rendered results page, so a bounded copy of the document travels back for
  the engine's `blocked?/1` and `gated?/1` markers to be read. Anything
  large is a real page and is never shipped whole.
  """
  def extraction_script, do: @extraction_script

  @doc """
  Inject Turndown into the page and extract its main section. `scope` is
  any Pinocchio parent: a session or a page.
  """
  def extract(scope) do
    with {:ok, _} <- Pinocchio.Browser.execute_script(scope, turndown_source()),
         {:ok, %{"result" => %{"value" => value}}} when is_map(value) <-
           Pinocchio.Browser.execute_script(scope, @extraction_script) do
      {:ok, value}
    else
      {:ok, _} -> {:error, :extraction_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `url` belongs to an interaction-heavy host whose useful content
  lives in a rendered section rather than the static document. Configured
  through `:neuron, :browser, :rich_hosts`.
  """
  def rich_host?(url) when is_binary(url) do
    host = url |> URI.parse() |> Map.get(:host) |> String.downcase()

    hosts =
      Application.get_env(:neuron, :browser, [])[:rich_hosts] || @default_rich_hosts

    is_binary(host) and
      Enum.any?(hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))
  catch
    _, _ -> false
  end

  def rich_host?(_), do: false
end
