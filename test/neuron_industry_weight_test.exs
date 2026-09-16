defmodule Neuron.IndustryWeightTest do
  use ExUnit.Case, async: true

  # Run 427e7708's campaign as it reached rank, and the two people it
  # rejected on industry alone (#81): a CTO and a VP of Engineering at an
  # insurance comparison marketplace, as the graph held them, pseudonymised
  # (people, company and domain; titles, industry and claim shape kept). The
  # company's industry is "insurance", which contains none of the campaign's
  # industry terms.
  @leaders "test/fixtures/427e7708_leaders.json" |> File.read!() |> Jason.decode!()

  @campaign %{
    seller_profile: %{domain: "nyx-labs.org", offer: "Offensive security assessments"},
    target_profile: %{
      geography: [],
      exclusions: [
        "agencies",
        "security vendors",
        "managed security providers",
        "bug bounty and disclosure programmes"
      ],
      industries: ["software", "SaaS", "fintech", "healthtech", "B2B software"],
      company_size: %{min: 20, max: 300},
      markets: [
        "Software product companies and SaaS businesses between 20 and 300 people that ship customer-facing systems handling payments, identity or personal data, and have no in-house security team."
      ],
      titles: [
        "CTO",
        "Chief Technology Officer",
        "VP of Engineering",
        "Vice President of Engineering"
      ],
      roles: [
        "Heads of engineering, VPs of engineering and CTOs at companies that build and ship their own software"
      ]
    }
  }

  @opts [require_contact_channel: false]

  test "427e7708's CTO and VP of Engineering pass the gates and reach rank" do
    {ranked, selection} = Neuron.Selection.select(@leaders, @campaign, [], @opts)

    assert Enum.sort(Enum.map(ranked, & &1.person_name)) == [
             "Gideon Shale",
             "Kasimir Hollen"
           ]

    assert selection.rejected == 0

    # The mismatch is still recorded, per person and in total, and costs
    # them the industry weight.
    for lead <- ranked do
      assert lead.industry_match == :mismatch
      assert lead.score_breakdown.industry == 0.0
    end

    assert selection.industry_by == %{match: 0, mismatch: 2, unknown: 0}
    refute Map.has_key?(selection.rejected_by, :industry)
  end

  test "a matching industry scores above a mismatch, all else equal" do
    matching =
      Enum.map(@leaders, fn record ->
        put_in(record, ["employer", "industry"], "insurance software")
      end)

    {[mismatched | _], _} = Neuron.Selection.select(@leaders, @campaign, [], @opts)
    {[matched | _], selection} = Neuron.Selection.select(matching, @campaign, [], @opts)

    assert matched.industry_match == :match
    assert matched.fit_score > mismatched.fit_score
    assert selection.industry_by.match == 2
  end

  test "a person at an excluded organization is still rejected" do
    excluded =
      Enum.map(@leaders, fn record ->
        put_in(
          record,
          ["employer", "description"],
          "One of the leading managed security providers"
        )
      end)

    {ranked, selection} = Neuron.Selection.select(excluded, @campaign, [], @opts)

    assert ranked == []
    assert selection.rejected_by.exclusion == 2

    for person <- selection.rejected_people do
      assert :exclusion in person.checks
      assert person.industry_match == :mismatch
    end
  end
end
