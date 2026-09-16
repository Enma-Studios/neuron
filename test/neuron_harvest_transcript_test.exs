defmodule Neuron.HarvestTranscriptTest do
  use ExUnit.Case, async: true

  defmodule Model do
    def complete(messages, _opts) do
      send(self(), {:harvest_prompt, List.last(messages).content})

      content =
        Jason.encode!(%{
          "results" => [
            %{"title" => "Team", "url" => "https://acme.example/team", "reason" => "team page"}
          ]
        })

      {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
    end
  end

  # A page runner that reports text and links but no Markdown, as the
  # campaign pipeline integration test's fake did. Every harvest raised, the
  # search stage retried, and the campaign never left :search (#51).
  test "a transcript without Markdown is harvested from its text" do
    transcript = %{
      url: "https://duckduckgo.com/html/?q=acme",
      title: "Search",
      text: "Acme leadership team",
      links: [%{href: "https://acme.example/team", label: "Team"}],
      engine: Neuron.Search.DuckDuckGo,
      query: "acme leadership"
    }

    assert {:ok, [%{url: "https://acme.example/team"}]} =
             Neuron.Search.Harvest.harvest(transcript, model_provider: Model)

    assert_received {:harvest_prompt, prompt}
    assert prompt =~ "Acme leadership team"
  end
end
