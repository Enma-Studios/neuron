defmodule Neuron.Search.AgentTest do
  use ExUnit.Case, async: true

  test "normalizes an extraction result into a search-tagged transcript" do
    raw = %{
      "url" => "https://social.example/search?keywords=acme",
      "title" => "acme — search",
      "markdown" => "## Results\n\n- [Jane Founder — CTO Acme](https://social.example/in/jane)",
      "text" => "Jane Founder\nCTO at Acme. Mark runs ops.",
      "links" => [
        %{"href" => "https://social.example/in/jane", "label" => "Jane Founder"},
        %{"href" => "https://social.example/in/jane", "label" => "duplicate"},
        %{"href" => "javascript:void(0)", "label" => "drop me"},
        %{"href" => "https://social.example/in/mark", "label" => "  Mark  "},
        "garbage"
      ]
    }

    task = %{
      id: {:stub, "q"},
      engine: Neuron.SearchTest.SocialEngine,
      query: "acme CTO",
      url: "https://social.example/search"
    }

    transcript = Neuron.Search.Agent.normalize(raw, task)

    assert transcript.url == "https://social.example/search?keywords=acme"
    assert transcript.title == "acme — search"
    assert transcript.markdown =~ "[Jane Founder — CTO Acme](https://social.example/in/jane)"
    assert transcript.text == "Jane Founder\nCTO at Acme. Mark runs ops."

    assert transcript.links == [
             %{href: "https://social.example/in/jane", label: "Jane Founder"},
             %{href: "https://social.example/in/mark", label: "Mark"}
           ]

    assert transcript.engine == Neuron.SearchTest.SocialEngine
    assert transcript.query == "acme CTO"
  end

  test "caps transcript content length and rejects non-map extractions" do
    long_text = String.duplicate("a", 20_000)
    task = %{id: {:stub, "q"}, engine: nil, query: "q", url: "https://x.example"}

    transcript = Neuron.Search.Agent.normalize(%{"url" => nil, "markdown" => long_text}, task)
    assert transcript.url == "https://x.example"
    assert String.length(transcript.markdown) == 16_000
    assert transcript.text == ""

    assert {:error, :invalid_transcript} = Neuron.Search.Agent.normalize("junk", task)
  end
end

defmodule Neuron.Browser.ScriptingTest do
  use ExUnit.Case, async: true

  test "ships a bundled Turndown build" do
    source = Neuron.Browser.Scripting.turndown_source()
    assert source =~ "TurndownService"
    assert byte_size(source) > 10_000
  end

  test "extraction script scopes to the main section and converts it" do
    script = Neuron.Browser.Scripting.extraction_script()

    assert script =~ ~s|[role="main"]|
    assert script =~ ~s|[data-testid="primaryColumn"]|
    assert script =~ "TurndownService"
    assert script =~ "cloneNode"
    assert script =~ "location.href"
    assert script =~ "innerText"
    assert script =~ "querySelectorAll('a[href]')"
  end

  test "flags interaction-heavy hosts" do
    assert Neuron.Browser.Scripting.rich_host?("https://www.linkedin.com/in/jane")
    assert Neuron.Browser.Scripting.rich_host?("https://x.com/search?q=acme")
    refute Neuron.Browser.Scripting.rich_host?("https://acme.example/team")
    refute Neuron.Browser.Scripting.rich_host?("garbage")
  end
end
