defmodule Neuron.LeadTest do
  use ExUnit.Case, async: true

  test "returns a score and transparent reasons for a selected fit" do
    candidate = %{name: "Acme", body: "Fintech payments platform", geography: "US"}

    fit = %{
      requirements: [%{category: "industry", description: "fintech payments"}],
      preferred_geographies: ["US"],
      threshold: 0.7
    }

    assert {:ok, decision} = Neuron.Lead.evaluate(candidate, fit)
    assert decision.selected
    assert decision.score == 1.0
    assert Enum.any?(decision.reasons, &String.starts_with?(&1, "Matched industry"))
    assert Enum.any?(decision.reasons, &String.starts_with?(&1, "Selected with score"))
    assert [%{criterion: "industry", excerpt: _}] = decision.evidence
  end

  test "explains why a candidate was rejected" do
    candidate = %{name: "Acme", body: "Retail store", geography: "EU"}

    fit = %{
      requirements: [%{category: "industry", description: "fintech payments"}],
      preferred_geographies: ["US"]
    }

    assert {:ok, decision} = Neuron.Lead.evaluate(candidate, fit)
    refute decision.selected
    assert Enum.any?(decision.reasons, &String.starts_with?(&1, "No evidence matched"))
    assert Enum.any?(decision.reasons, &String.starts_with?(&1, "Not selected with score"))
  end
end

defmodule Neuron.IntelligenceTest do
  use ExUnit.Case, async: false

  defmodule BrowserAdapter do
    def fetch(url, _opts),
      do:
        {:ok,
         %{
           url: url,
           title: "Fintech platform",
           geography: "US",
           html: "<main><h1>Fintech platform</h1><p>Payments for US teams.</p></main>"
         }}
  end

  test "explores, embeds, scores, and returns a snapshot" do
    fit = %{
      requirements: [%{category: "industry", description: "fintech payments"}],
      preferred_geographies: ["US"],
      threshold: 0.7
    }

    assert {:ok, result} =
             Neuron.Intelligence.explore("https://example.test", fit,
               adapter: BrowserAdapter,
               embedding_provider: Neuron.Embedding.Stub,
               run_id: "intelligence-test",
               persist: false
             )

    assert result.decision.selected
    assert result.decision.score == 1.0
    assert result.snapshot.markdown =~ "Fintech platform"
  end
end
