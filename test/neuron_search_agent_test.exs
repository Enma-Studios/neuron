defmodule Neuron.Search.AgentTest do
  use ExUnit.Case, async: true

  test "normalizes an extraction result into a search-tagged transcript" do
    raw = %{
      "url" => "https://social.example/search?keywords=acme",
      "title" => "acme — search",
      "text" => "Jane Founder\nCTO at Acme\n",
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
    assert transcript.text == "Jane Founder\nCTO at Acme"

    assert transcript.links == [
             %{href: "https://social.example/in/jane", label: "Jane Founder"},
             %{href: "https://social.example/in/mark", label: "Mark"}
           ]

    assert transcript.engine == Neuron.SearchTest.SocialEngine
    assert transcript.query == "acme CTO"
  end

  test "caps transcript text length and rejects non-map extractions" do
    long_text = String.duplicate("a", 20_000)
    task = %{id: {:stub, "q"}, engine: nil, query: "q", url: "https://x.example"}

    transcript = Neuron.Search.Agent.normalize(%{"url" => nil, "text" => long_text}, task)
    assert transcript.url == "https://x.example"
    assert String.length(transcript.text) == 16_000

    assert {:error, :invalid_transcript} = Neuron.Search.Agent.normalize("junk", task)
  end

  test "extraction script reads location, title, body text, and links" do
    script = Neuron.Search.Agent.extraction_script()

    assert script =~ "location.href"
    assert script =~ "document.title"
    assert script =~ "innerText"
    assert script =~ "querySelectorAll('a[href]')"
  end
end
