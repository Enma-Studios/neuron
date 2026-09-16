defmodule Neuron.Campaign.IntakeAnswersTest do
  use ExUnit.Case, async: false

  # Run 92406981's intake: the host answered, the seller page was scraped, and
  # the scrape proposed exactly one campaign. Its answers came back replaced
  # by the page's own sentences.
  @roles "Heads of engineering, VPs of engineering and CTOs at companies that build and ship their own software"
  @organizations "Software product companies and SaaS businesses between 20 and 300 people that ship customer-facing systems handling payments, identity or personal data, and have no in-house security team."
  @offer "We find where trust breaks, strengthen the systems around it, and help an organization stay ready for what comes next."
  @exclusions ["agencies", "security vendors", "bug bounty or disclosure programmes"]

  # As the host sends them: every intake key present, unanswered ones nil.
  @answers %{
    url: "https://nyx-labs.org/",
    organization: "Nyx Labs",
    domain: nil,
    field:
      "An independent security practice. Offensive and defensive security research and engineering.",
    offer: @offer,
    target_roles: @roles,
    target_organizations: @organizations,
    geography: nil,
    exclusions: nil,
    seller_geography: nil,
    lead_count: 1
  }

  defmodule Browser do
    def fetch(_url, _opts),
      do: {:ok, %{html: File.read!("test/fixtures/nyx-labs.html"), title: "Nyx Labs"}}
  end

  # The shape the intake model returned for nyx-labs.org: its own reading of
  # the page at the top level, and one proposed campaign repeating it.
  defmodule Model do
    @json """
    {
      "organization": "Nyx Labs",
      "domain": "nyx-labs.org",
      "field": "An independent security practice. Offensive and defensive security research and engineering.",
      "offer": "Direct client engagements spanning offensive security assessments and custom security tooling.",
      "seller_geography": ["Global (stated operational range)"],
      "target_roles": ["security teams", "technology leaders"],
      "target_organizations": ["Organizations whose products, infrastructure, and users cannot be treated as abstractions"],
      "geography": [],
      "exclusions": [],
      "campaigns": [{
        "name": "Security services engagements (offensive and defensive)",
        "organization": "Nyx Labs",
        "domain": "nyx-labs.org",
        "offer": "Direct client engagements spanning offensive security assessments and custom security tooling.",
        "target_roles": ["security teams", "technology leaders"],
        "target_organizations": ["Organizations whose products, infrastructure, and users cannot be treated as abstractions"],
        "exclusions": []
      }],
      "sources": {
        "target_roles": "technology leaders trust Nyx Labs to find what others miss.",
        "seller_geography": "technology leaders trust Nyx Labs to find what others miss."
      }
    }
    """

    def complete(_messages, _opts),
      do: {:ok, %{"choices" => [%{"message" => %{"content" => @json}}]}}
  end

  defp intake(answers),
    do: Neuron.Campaign.intake(answers, adapter: Browser, model_provider: Model)

  # Intake saves the page to Dgraph before it extracts, like every test that
  # reaches `save_document`.
  describe "intake with a scraped seller page" do
    @describetag :integration

    setup do
      connection = Neuron.Dgraph.connection()
      assert is_pid(connection), "integration requires a configured Dgraph connection"
      {:ok, _} = Neuron.Graph.Schema.apply(connection)
      :ok
    end

    test "supplied answers survive byte-identical" do
      assert {:ok, campaign} = intake(@answers)

      assert campaign.target_profile.roles == [@roles]
      assert campaign.target_profile.markets == [@organizations]
      assert campaign.seller_profile.offer == @offer
      # The page did not supply these, so it is not cited as their source.
      refute Map.has_key?(campaign.field_sources, :target_roles)
    end

    test "an unanswered field is derived from the page" do
      assert {:ok, campaign} = intake(@answers)

      assert campaign.seller_profile.geography == ["Global (stated operational range)"]
      assert Map.has_key?(campaign.field_sources, :seller_geography)
    end

    test "supplied exclusions reach target_profile" do
      assert {:ok, campaign} = intake(%{@answers | exclusions: @exclusions})

      assert campaign.target_profile.exclusions == @exclusions
    end
  end
end
