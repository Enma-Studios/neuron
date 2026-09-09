defmodule Neuron.Search.HarvestTest do
  use ExUnit.Case, async: true

  defp transcript do
    %{
      url: "https://social.example/search?keywords=acme",
      title: "acme — search",
      markdown: "## Results\n\n- [Jane Founder — CTO Acme](https://social.example/in/jane)",
      text: "Jane Founder CTO at Acme. Mark runs ops.",
      links: [
        %{href: "https://social.example/in/jane", label: "Jane Founder — CTO Acme"},
        %{href: "https://acme.example/team", label: "Acme team"},
        %{href: "https://nav.example/home", label: "Home"}
      ],
      engine: Neuron.SearchTest.SocialEngine,
      query: "acme CTO"
    }
  end

  test "harvest returns model selections normalized and deduplicated" do
    assert {:ok, [result]} =
             Neuron.Search.Harvest.harvest(transcript(),
               model_provider: Neuron.SearchTest.SelectingModel
             )

    assert result.url == "https://social.example/in/jane"
    assert result.title == "Jane Founder — CTO Acme"
    assert result.reason == "decision maker at buyer"
  end

  test "harvest rejects URLs that are not in the transcript" do
    assert {:error, {:invalid_model_output, _}} =
             Neuron.Search.Harvest.harvest(transcript(),
               model_provider: Neuron.SearchTest.HallucinatingModel
             )
  end

  test "from_transcripts records harvest failures without fabricating results" do
    assert {[], [failure]} =
             Neuron.Search.Harvest.from_transcripts([transcript()],
               model_provider: Neuron.SearchTest.FailingModel
             )

    assert failure.engine == Neuron.SearchTest.SocialEngine
    assert failure.query == "acme CTO"
    assert failure.reason =~ "planner_down"
  end
end
