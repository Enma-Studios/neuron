defmodule Neuron.SellerDomainTest do
  use ExUnit.Case, async: true

  # Run 92450aed's campaign as intake produced it (#68): the host sent the
  # URL, and the intake model returned a phrase from the page as `domain`.
  @campaign %{
    url: "https://nyx-labs.org/",
    source_url: "https://nyx-labs.org/",
    organization: "Nyx Labs",
    domain: "Security Research & Engineering",
    field:
      "An independent security practice. Offensive and defensive security research and engineering.",
    offer: "Direct client engagements spanning offensive security assessments",
    target_roles:
      "Heads of engineering, VPs of engineering and CTOs at companies that build and ship their own software",
    target_organizations:
      "Software product companies and SaaS businesses between 20 and 300 people",
    lead_count: 1
  }

  test "the seller domain is the input URL's registrable domain, never a field value" do
    assert {:ok, campaign} = Neuron.Campaign.normalize_campaign(@campaign)

    assert campaign.domain == "nyx-labs.org"
    assert campaign.seller_profile.domain == "nyx-labs.org"
  end

  test "a subdomain URL gives the registrable domain" do
    for {url, domain} <- [
          {"https://www.nyx-labs.org/about", "nyx-labs.org"},
          {"https://careers.booking.com/teams/leadership/", "booking.com"},
          {"https://shop.example.co.uk/", "example.co.uk"}
        ] do
      assert {:ok, campaign} = Neuron.Campaign.normalize_campaign(%{@campaign | url: url})
      assert campaign.seller_profile.domain == domain, url
    end
  end

  test "without a URL, a phrase is not accepted as the seller domain" do
    assert {:needs_input, %{reason: :organization_domain_required}} =
             Neuron.Campaign.normalize_campaign(Map.drop(@campaign, [:url, :source_url]))
  end

  # A Nyx Labs engineer on nyx-labs.org's own team page, who would otherwise
  # match every check: named, titled CTO, employer observed on the employer's
  # own domain.
  defp seller_employee do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %{
      "uid" => "0x1",
      "external_id" => "person-nyx",
      "assertions" =>
        for {predicate, value} <- %{
              "name" => "A. Researcher",
              "title" => "CTO",
              "employer" => "nyx-labs.org"
            } do
          %{
            "uid" => "0x1#{predicate}",
            "predicate" => predicate,
            "claim_value" => value,
            "excerpt" => value,
            "url" => "https://nyx-labs.org/team",
            "observed_at" => now,
            "authority" => 1.0,
            "assertion_kind" => "observed"
          }
        end
    }
  end

  test "the seller check rejects the seller's own people on 92450aed's campaign" do
    {:ok, campaign} = Neuron.Campaign.normalize_campaign(@campaign)
    campaign = put_in(campaign, [:target_profile, :titles], ["CTO"])

    assert {[], selection} =
             Neuron.Selection.select([seller_employee()], campaign, [],
               require_contact_channel: false
             )

    assert selection.rejected_by.seller == 1
  end
end
