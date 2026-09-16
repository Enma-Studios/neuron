defmodule Neuron.ExclusionsTest do
  use ExUnit.Case, async: true

  @prose "Not agencies, not security vendors, not bug bounty or disclosure programmes."

  test "a prose exclusion becomes one term per clause" do
    {:ok, campaign} =
      Neuron.Campaign.normalize_campaign(%{
        organization: "Nyx Labs",
        domain: "nyx-labs.org",
        field: "Security",
        offer: "Assessments",
        target_roles: "CTO",
        target_organizations: "Software product companies",
        exclusions: @prose,
        lead_count: 1
      })

    assert campaign.target_profile.exclusions ==
             ["agencies", "security vendors", "bug bounty or disclosure programmes"]
  end

  # A CTO whose own facts say nothing about what their company is. Only the
  # employer organization's description can.
  defp person(description) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    claims =
      for {predicate, value} <- %{
            "name" => "Ada",
            "title" => "CTO",
            "employer" => "vendor.example"
          },
          do: %{
            "uid" => "0x1#{predicate}",
            "predicate" => predicate,
            "claim_value" => value,
            "excerpt" => value,
            "url" => "https://vendor.example/team",
            "observed_at" => now,
            "authority" => 1.0,
            "assertion_kind" => "observed"
          }

    %{
      "uid" => "0x1",
      "external_id" => "person-ada",
      "assertions" => claims,
      "employer" => %{
        "name" => "Vendor",
        "industry" => "Software",
        "description" => description
      }
    }
  end

  defp campaign do
    %{
      seller_profile: %{domain: "nyx-labs.org", offer: "security assessments"},
      target_profile: %{
        markets: [],
        roles: ["CTO"],
        geography: [],
        exclusions: ["agencies", "security vendors"]
      }
    }
  end

  @opts [require_contact_channel: false]

  test "a person at an organization described by an excluded term is rejected, and counted" do
    record = person("One of the leading security vendors for mid-market companies")

    assert {[], selection} = Neuron.Selection.select([record], campaign(), [], @opts)
    assert selection.rejected_by.exclusion == 1
  end

  test "the same person at an organization without the term passes" do
    record = person("A payments platform for independent retailers")

    assert {[lead], selection} = Neuron.Selection.select([record], campaign(), [], @opts)
    assert lead.person_name == "Ada"
    assert selection.rejected_by.exclusion == 0
  end
end
