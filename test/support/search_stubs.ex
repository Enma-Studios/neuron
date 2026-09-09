# Test doubles for the search engine fan-out. Compiled into the test build
# through `elixirc_paths` so library code can call them as ordinary modules.
defmodule Neuron.SearchTest.WebEngine do
  @behaviour Neuron.Search.Engine

  def kind, do: :web
  def keywords(query), do: query
  def search_url(keywords), do: "https://web.example/search?q=#{URI.encode_www_form(keywords)}"

  def parse(_html) do
    [
      %{title: "Web only", url: "https://web.example/only", snippet: ""},
      %{title: "Shared", url: "https://shared.example/founder", snippet: ""}
    ]
  end

  def blocked?(_html), do: false
  def gated?(_html), do: false
end

defmodule Neuron.SearchTest.SocialEngine do
  @behaviour Neuron.Search.Engine

  def kind, do: :social

  def keywords(query), do: Neuron.Search.Engine.strip_site_operators(query)

  def search_url(keywords),
    do: "https://social.example/search?keywords=#{URI.encode_www_form(keywords)}"

  def parse(_html) do
    [
      %{title: "Shared", url: "https://shared.example/founder", snippet: ""},
      %{title: "Social only", url: "https://social.example/only", snippet: ""}
    ]
  end

  def blocked?(_html), do: false
  def gated?(_html), do: false
end

defmodule Neuron.SearchTest.GatedEngine do
  @behaviour Neuron.Search.Engine

  def kind, do: :social

  def keywords(query), do: Neuron.Search.Engine.strip_site_operators(query)

  def search_url(keywords),
    do: "https://gate.example/search?q=#{URI.encode_www_form(keywords)}"

  def parse(_html), do: [%{title: "Never", url: "https://gated.example/never", snippet: ""}]
  def blocked?(_html), do: false
  def gated?(html), do: String.contains?(html, "gate-page")
end

defmodule Neuron.SearchTest.PageAdapter do
  def run_page(_handle, task, _opts),
    do: {:ok, %{url: task.url, title: "page", html: "gate-page for #{task.url}"}}
end

defmodule Neuron.SearchTest.PlanningModel do
  def complete(_messages, _opts) do
    content =
      Jason.encode!(%{
        "searches" => [
          %{"engine" => "webengine", "query" => "acme CTO email"},
          %{"engine" => "webengine", "query" => "acme CTO email"},
          %{"engine" => "socialengine", "query" => "acme founder"},
          %{"engine" => "bogus", "query" => "unknown platform"}
        ]
      })

    {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
  end
end

defmodule Neuron.SearchTest.RaisingModel do
  def complete(_messages, _opts), do: raise("planning must not run")
end

defmodule Neuron.SearchTest.FailingModel do
  def complete(_messages, _opts), do: {:error, :planner_down}
end

defmodule Neuron.SearchTest.SelectingModel do
  def complete(_messages, _opts) do
    content =
      Jason.encode!(%{
        "results" => [
          %{
            "title" => "Jane Founder — CTO Acme",
            "url" => "https://social.example/in/jane",
            "reason" => "decision maker at buyer"
          },
          %{
            "title" => "Jane again",
            "url" => "https://social.example/in/jane",
            "reason" => "duplicate"
          }
        ]
      })

    {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
  end
end

defmodule Neuron.SearchTest.HallucinatingModel do
  def complete(_messages, _opts) do
    content =
      Jason.encode!(%{
        "results" => [
          %{"title" => "Ghost", "url" => "https://invented.example/ghost", "reason" => "nope"}
        ]
      })

    {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
  end
end

defmodule Neuron.SearchTest.LoginEngine do
  @behaviour Neuron.Search.Engine

  def kind, do: :social
  def keywords(query), do: query

  def search_url(keywords),
    do: "https://gate.example/login?q=#{URI.encode_www_form(keywords)}"

  def parse(_html), do: []
  def blocked?(_html), do: false
  def gated?(_html), do: true
end

defmodule Neuron.SearchTest.TranscriptAgent do
  def run_page(_handle, task, opts) do
    domain = Keyword.get(opts, :fixture_domain, "acme.example")

    {:ok,
     %{
       url: task.url,
       title: "Search",
       text: "Results for #{task.query}",
       links: [%{href: "https://#{domain}/team", label: "Team"}],
       engine: task.engine,
       query: task.query
     }}
  end
end

defmodule Neuron.SearchTest.TeamHarvestModel do
  def complete(_messages, opts) do
    domain = Keyword.get(opts, :fixture_domain, "acme.example")

    content =
      Jason.encode!(%{
        "results" => [
          %{"title" => "Team", "url" => "https://#{domain}/team", "reason" => "buyer team"}
        ]
      })

    {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
  end
end
