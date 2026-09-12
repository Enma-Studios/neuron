defmodule Neuron.Campaign.IntakeErrorsTest do
  use ExUnit.Case, async: false

  # The eight intake answers, all of them, as the repro sends them.
  @answers %{
    organization: "Enma Studios",
    field: "Software product studio",
    offer: "A small senior team that builds, rebuilds or extends your product",
    target_roles: ["Founder", "CTO"],
    target_organizations: ["Companies with fewer than five engineers"],
    geography: ["United Kingdom"],
    exclusions: ["branch offices"],
    lead_count: 3
  }

  defmodule UnusableBodyBrowser do
    # A site that answers 200 with nothing the snapshot can use. The page was
    # reachable; the step that failed is not the fetch.
    def fetch(_url, _opts), do: {:ok, %{html: nil, title: "Enma", url: "https://enma.example"}}
  end

  defmodule UnreachableBrowser do
    def fetch(_url, _opts), do: {:error, :browser_use_not_configured}
  end

  defmodule SilentModel do
    def complete(_messages, _opts), do: {:error, :model_unavailable}
  end

  test "eight answers and a URL that will not parse still produce a campaign" do
    # The repro: every question answered, and the answers come back. Scraping
    # fills what is missing; it is not a precondition for what was supplied.
    assert {:ok, campaign} =
             Neuron.Campaign.intake(
               Map.put(@answers, :url, "https://enma.example"),
               adapter: UnusableBodyBrowser,
               model_provider: SilentModel
             )

    assert campaign.organization == "Enma Studios"
    assert campaign.lead_count == 3
    assert campaign.target_profile.roles == ["Founder", "CTO"]
  end

  test "eight answers and an unreachable URL still produce a campaign" do
    assert {:ok, campaign} =
             Neuron.Campaign.intake(
               Map.put(@answers, :url, "https://enma.example"),
               adapter: UnreachableBrowser,
               model_provider: SilentModel
             )

    assert campaign.organization == "Enma Studios"
  end

  test "a step after the fetch is not reported as a URL problem" do
    # Answers deliberately incomplete, so intake has to ask. What it must not
    # do is blame the URL for a step the URL had nothing to do with: this site
    # answered 200.
    assert {:needs_input, details} =
             Neuron.Campaign.intake(
               %{organization: "Enma Studios", url: "https://enma.example"},
               adapter: UnusableBodyBrowser,
               model_provider: SilentModel
             )

    assert {:html, :missing} = details.scrape_error
    refute details[:reason] == :url_unavailable
  end

  test "a fetch failure names the fetch, and the answers are still carried" do
    assert {:needs_input, details} =
             Neuron.Campaign.intake(
               %{organization: "Enma Studios", url: "https://enma.example"},
               adapter: UnreachableBrowser,
               model_provider: SilentModel
             )

    assert {:fetch, :browser_use_not_configured} = details.scrape_error
    assert details.partial[:organization] == "Enma Studios"

    # The symptom this issue was filed for: the old `:url_unavailable` branch
    # returned `questions()`, the whole set of eight, and threw the answers
    # away. Only the unanswered ones are asked for now.
    keys = Enum.map(details.questions, & &1.key)
    refute :organization in keys
    assert length(keys) < 8
  end

  test "no URL at all is unchanged: answers alone still work" do
    assert {:ok, campaign} = Neuron.Campaign.intake(@answers, model_provider: SilentModel)
    assert campaign.organization == "Enma Studios"
  end

  test "incomplete answers and no URL ask for what is missing, with no scrape error" do
    assert {:needs_input, details} =
             Neuron.Campaign.intake(%{organization: "Enma Studios"}, model_provider: SilentModel)

    refute Map.has_key?(details, :scrape_error)

    # Only what is missing is asked for, never the whole set again.
    keys = Enum.map(details.questions, & &1.key)
    refute :organization in keys
    assert :field in keys
  end
end
