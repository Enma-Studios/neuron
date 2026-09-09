defmodule Neuron.SearchTest do
  use ExUnit.Case, async: true

  test "parses DuckDuckGo result links, snippets, and redirect URLs" do
    html = """
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone">One &amp; Co</a>
    <a class="result__snippet">First <b>result</b></a>
    <a class="result__a" href="https://example.com/two">Two</a>
    <a class="result__snippet">Second result</a>
    """

    assert [
             %{title: "One & Co", url: "https://example.com/one", snippet: "First result"},
             %{title: "Two", url: "https://example.com/two", snippet: "Second result"}
           ] = Neuron.Search.DuckDuckGo.parse(html)
  end
end
