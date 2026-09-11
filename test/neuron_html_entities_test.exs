defmodule Neuron.Search.HtmlEntitiesTest do
  use ExUnit.Case, async: true

  alias Neuron.Search.Engine

  test "decodes the entities that reach a lead title" do
    assert Engine.html_entities("Ada &amp; Co") == "Ada & Co"
    assert Engine.html_entities("5 &lt; 6 &gt; 4") == "5 < 6 > 4"

    assert Engine.html_entities("&quot;quoted&quot; and &apos;quoted&apos;") ==
             ~s("quoted" and 'quoted')
  end

  test "decodes the punctuation a search snippet is full of" do
    assert Engine.html_entities("Team &mdash; Acme") == "Team — Acme"
    assert Engine.html_entities("2024&ndash;2025") == "2024–2025"
    assert Engine.html_entities("It&rsquo;s here&hellip;") == "It’s here..."
    assert Engine.html_entities("&ldquo;quoted&rdquo;") == "“quoted”"
  end

  test "decodes a name rather than letting it reach a lead as markup" do
    assert Engine.html_entities("Bj&ouml;rn M&uuml;ller") == "Björn Müller"
    assert Engine.html_entities("Caf&eacute; Ni&ntilde;o") == "Café Niño"
    assert Engine.html_entities("Ren&eacute;e Fran&ccedil;ois") == "Renée François"
  end

  test "decodes any numeric entity, which is where the long tail lives" do
    assert Engine.html_entities("caf&#233; caf&#xE9; caf&#XE9;") == "café café café"
    assert Engine.html_entities("&#8212;") == "—"
    assert Engine.html_entities("&#128640;") == "\u{1F680}"
  end

  test "leaves anything it cannot decode exactly as written" do
    # Mangling an unknown entity into something that looks decoded would be
    # worse than leaving it, because nobody could tell afterwards.
    for untouched <- [
          "&unknownthing; stays",
          "&#999999999; stays",
          "&#xFFFFFFF; stays",
          "AT&T and Johnson & Johnson",
          "a & b",
          "&;",
          "&#;"
        ] do
      assert Engine.html_entities(untouched) == untouched
    end
  end

  test "a surrogate codepoint is not decoded into something invalid" do
    assert Engine.html_entities("&#xD800;") == "&#xD800;"
    assert Engine.html_entities("&#55296;") == "&#55296;"
  end

  test "decodes in one pass, so a double-encoded entity stays encoded once" do
    # The old implementation replaced &amp; first and decoded this twice,
    # turning an escaped entity into a real tag delimiter.
    assert Engine.html_entities("&amp;lt;script&amp;gt;") == "&lt;script&gt;"
  end

  test "passes through anything that is not a string" do
    assert Engine.html_entities(nil) == nil
    assert Engine.html_entities(42) == 42
  end

  test "the engines that decode entities still parse their own results" do
    assert [%{url: "https://example.com/about", title: "Ada & Co"}] =
             Neuron.Search.Google.parse(
               ~s(<a href="/url?q=https%3A%2F%2Fexample.com%2Fabout&amp;sa=U">Ada &amp; Co</a>)
             )
  end
end
