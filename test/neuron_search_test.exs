defmodule Neuron.SearchTest do
  use ExUnit.Case, async: true

  test "parses DuckDuckGo result links and ignores non-results" do
    html =
      """
      <a class="result__a" href="https://example.com/team">Leadership team</a>
      <a class="other" href="https://example.com/ignored">Ignored</a>
      """

    assert [result] = Neuron.Search.DuckDuckGo.parse(html)
    assert result.url == "https://example.com/team"
    assert result.title == "Leadership team"
  end
end
