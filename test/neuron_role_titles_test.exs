defmodule Neuron.RoleTitlesTest do
  use ExUnit.Case, async: true

  # The people run 92406981 found on ciso.inc's leadership page, and the two
  # it found elsewhere, as the graph holds them: sourced names and employers,
  # titles where the page gave one, no location, no email.
  defp person(id, facts, url \\ "https://www.ciso.inc/company/leadership") do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %{
      "uid" => "0x#{id}",
      "external_id" => "person-#{id}",
      "assertions" =>
        for {predicate, value} <- facts do
          %{
            "uid" => "0x#{id}#{predicate}",
            "predicate" => predicate,
            "claim_value" => value,
            "excerpt" => value,
            "url" => url,
            "observed_at" => now,
            "authority" => if(url =~ "linkedin", do: 0.8, else: 1.0),
            "assertion_kind" => "observed"
          }
        end
    }
  end

  defp people do
    [
      person(1, %{"name" => "Gary Perkins", "title" => "CISO", "employer" => "ciso.inc"}),
      person(2, %{"name" => "Deb Smith", "title" => "CFO", "employer" => "ciso.inc"}),
      person(3, %{"name" => "David Jemmett", "title" => "CEO & Founder", "employer" => "ciso.inc"}),
      person(4, %{"name" => "Robert C. Oaks", "title" => "Director", "employer" => "ciso.inc"}),
      person(5, %{"name" => "Andrew Hancox", "employer" => "ciso.inc"}),
      person(
        6,
        %{"name" => "Sebastián Vargas", "title" => "CEO TTPSEC SPA"},
        "https://www.linkedin.com/pulse/como-crear-un-plan"
      )
    ]
  end

  defp campaign(target) do
    %{
      seller_profile: %{domain: "nyx-labs.org", offer: "security assessments"},
      target_profile: Map.merge(%{markets: [], roles: [], geography: [], exclusions: []}, target)
    }
  end

  @opts [require_contact_channel: false]

  test "category roles match no title, and every rejection is counted by the check that failed" do
    target = campaign(%{roles: ["security teams", "technology leaders"]})

    {ranked, selection} = Neuron.Selection.select(people(), target, [], @opts)

    assert ranked == []
    assert selection.considered == 6
    assert selection.ranked == 0
    assert selection.rejected == 6
    assert selection.withheld_contact == 0
    # Every person fails the role check; Vargas also has no employer.
    assert selection.rejected_by.role == 6
    assert selection.rejected_by.employer == 1
    assert selection.rejected_by.name == 0
  end

  test "expanded titles match whole words in a title, never a substring of another word" do
    target = campaign(%{roles: ["technology leaders"], titles: ["CTO", "CISO"]})

    {ranked, selection} = Neuron.Selection.select(people(), target, [], @opts)

    assert Enum.map(ranked, & &1.person_name) == ["Gary Perkins"]
    # "Director" contains the letters c-t-o and must not match "CTO".
    assert selection.rejected_by.role == 5
    assert selection.ranked == 1
  end

  test "a match below the selection threshold is counted as such" do
    target = campaign(%{roles: ["CISO"]})

    {[], selection} =
      Neuron.Selection.select(
        people(),
        target,
        [],
        Keyword.put(@opts, :selection_threshold, 0.99)
      )

    assert selection.rejected_by.threshold == 1
  end

  defmodule TitlesModel do
    def complete(messages, _opts) do
      prompt = List.last(messages).content
      send(self(), {:titles_prompt, prompt})

      {:ok,
       %{
         "choices" => [
           %{"message" => %{"content" => ~s({"titles": ["CTO", " VP Engineering ", "CTO", ""]})}}
         ]
       }}
    end
  end

  test ":prepare expands the campaign's roles into concrete job titles" do
    input = campaign(%{roles: ["technology leaders"]})

    assert {:ok, data} =
             Neuron.CampaignPipeline.stage(:prepare, input, model_provider: TitlesModel)

    assert_received {:titles_prompt, prompt}
    assert prompt =~ "technology leaders"
    assert data.campaign.target_profile.titles == ["CTO", "VP Engineering"]
    assert data.campaign.target_profile.roles == ["technology leaders"]
  end

  test ":prepare makes no model call when there are no roles to expand" do
    assert {:ok, data} =
             Neuron.CampaignPipeline.stage(:prepare, campaign(%{}), model_provider: TitlesModel)

    refute_received {:titles_prompt, _}
    assert data.campaign.target_profile.titles == []
  end
end
