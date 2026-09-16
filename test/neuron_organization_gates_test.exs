defmodule Neuron.OrganizationGatesTest do
  use ExUnit.Case, async: true

  test "the campaign carries company size and industries into target_profile" do
    {:ok, campaign} =
      Neuron.Campaign.normalize_campaign(%{
        organization: "Nyx Labs",
        domain: "nyx-labs.org",
        field: "Security",
        offer: "Assessments",
        target_roles: "CTO",
        target_organizations: "Software product companies",
        company_size: %{min: 20, max: 300},
        industries: ["software", "SaaS"],
        lead_count: 1
      })

    assert campaign.target_profile.company_size == %{min: 20, max: 300}
    assert campaign.target_profile.industries == ["software", "SaaS"]
  end

  test "a string size bound is rejected at intake, naming the field and value" do
    # An integer always sorts below a string, so "20" would have rejected
    # every organization that states a size (#73).
    base = %{
      organization: "Nyx Labs",
      domain: "nyx-labs.org",
      field: "Security",
      offer: "Assessments",
      target_roles: "CTO",
      target_organizations: "Software product companies",
      lead_count: 1
    }

    assert {:error, {:invalid_company_size, :min, "20"}} =
             Neuron.Campaign.normalize_campaign(
               Map.put(base, :company_size, %{min: "20", max: 300})
             )

    assert {:error, {:invalid_company_size, :max, "300"}} =
             Neuron.Campaign.normalize_campaign(
               Map.put(base, :company_size, %{"min" => 20, "max" => "300"})
             )

    assert {:ok, %{target_profile: %{company_size: %{min: 20, max: nil}}}} =
             Neuron.Campaign.normalize_campaign(Map.put(base, :company_size, %{min: 20}))
  end

  test "an organization may state its employee count" do
    document = %{url: "https://acme.example/about", markdown: "Acme has 120 employees."}

    assert {:ok, [claim]} =
             Neuron.Knowledge.validate_claims(
               %{
                 "claims" => [
                   %{
                     "entity_type" => "Organization",
                     "identity" => "acme.example",
                     "predicate" => "employee_count",
                     "value" => "120",
                     "excerpt" => "Acme has 120 employees.",
                     "source_url" => "https://acme.example/about"
                   }
                 ]
               },
               document
             )

    assert claim.predicate == "employee_count"
  end

  # A CTO at an organization whose facts are exactly `organization`, as the
  # candidate query returns the employer.
  defp cto_at(organization) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    claims =
      for {predicate, value} <- %{
            "name" => "Ada",
            "title" => "CTO",
            "employer" => "acme.example"
          },
          do: %{
            "uid" => "0x1#{predicate}",
            "predicate" => predicate,
            "claim_value" => value,
            "excerpt" => value,
            "url" => "https://acme.example/team",
            "observed_at" => now,
            "authority" => 1.0,
            "assertion_kind" => "observed"
          }

    %{
      "uid" => "0x1",
      "external_id" => "person-ada",
      "assertions" => claims,
      "employer" => organization
    }
  end

  defp campaign do
    %{
      seller_profile: %{domain: "nyx-labs.org", offer: "security assessments"},
      target_profile: %{
        markets: [],
        roles: ["CTO"],
        geography: [],
        exclusions: [],
        company_size: %{min: 20, max: 300},
        industries: ["software", "SaaS"]
      }
    }
  end

  defp select(organization),
    do:
      Neuron.Selection.select([cto_at(organization)], campaign(), [],
        require_contact_channel: false
      )

  defp facts(map), do: %{"knowledge_json" => Jason.encode!(map)}

  describe "size" do
    test "an organization observed outside the range is rejected, and counted" do
      assert {[], selection} =
               select(Map.put(facts(%{"employee_count" => "5,000+"}), "industry", "Software"))

      assert selection.rejected_by.size == 1
    end

    test "an organization observed inside the range passes" do
      assert {[_lead], selection} =
               select(Map.put(facts(%{"employee_count" => "51-200"}), "industry", "Software"))

      assert selection.rejected_by.size == 0
    end

    test "an organization with no observed size passes, and is counted as unknown" do
      assert {[_lead], selection} = select(Map.put(facts(%{}), "industry", "Software"))

      assert selection.rejected_by.size == 0
      assert selection.unknown_by.size == 1
    end
  end

  describe "industry" do
    test "an organization whose industry and description match no term is rejected, and counted" do
      organization =
        facts(%{"employee_count" => "120"})
        |> Map.merge(%{"industry" => "Travel and e-commerce", "description" => "Online travel"})

      assert {[], selection} = select(organization)
      assert selection.rejected_by.industry == 1
    end

    test "a term in the description is enough" do
      organization =
        facts(%{"employee_count" => "120"})
        |> Map.put("description", "A SaaS payroll platform for small businesses")

      assert {[_lead], selection} = select(organization)
      assert selection.rejected_by.industry == 0
    end

    test "a term must be a whole word" do
      # "software" is not in "softwareless", and "SaaS" is not in "SaaSy".
      organization =
        facts(%{"employee_count" => "120"})
        |> Map.put("description", "A softwareless, SaaSy agency")

      assert {[], selection} = select(organization)
      assert selection.rejected_by.industry == 1
    end

    test "an organization with no industry or description passes, and is counted as unknown" do
      assert {[_lead], selection} = select(facts(%{"employee_count" => "120"}))

      assert selection.rejected_by.industry == 0
      assert selection.unknown_by.industry == 1
    end
  end
end
