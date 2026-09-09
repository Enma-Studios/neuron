defmodule Neuron.CampaignTest do
  use ExUnit.Case, async: true

  test "keeps intake bounded to eight questions" do
    assert length(Neuron.Campaign.questions()) == 8
    assert Enum.all?(Neuron.Campaign.questions(), &Map.has_key?(&1, :key))

    assert {:needs_input, %{questions: questions}} = Neuron.Campaign.intake(%{})
    assert length(questions) <= 8
  end

  test "normalizes a complete answer set into a research profile" do
    assert {:ok, campaign} =
             Neuron.Campaign.intake(%{
               organization: "https://acme.example",
               field: "B2B security",
               offer: "security assessments",
               target_roles: ["CTO"],
               geography: ["US"],
               lead_count: 2
             })

    assert campaign.domain == "acme.example"
    assert campaign.lead_count == 2
    assert campaign.fit_profile.preferred_geographies == ["US"]

    assert %{category: "field", description: "B2B security"} in campaign.fit_profile.requirements
    assert %{category: "target_role", description: "CTO"} in campaign.fit_profile.requirements
  end

  test "a profile can supply the detailed fit fields" do
    assert {:ok, campaign} =
             Neuron.Campaign.intake(%{
               domain: "acme.example",
               fit_profile: %{requirements: [%{description: "security"}]},
               lead_count: 1
             })

    assert campaign.domain == "acme.example"
  end
end
