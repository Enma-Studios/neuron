defmodule Neuron.RoleTitlesTest do
  use ExUnit.Case, async: true

  # The people run 92406981 found on a security vendor's leadership page, and
  # the one it found elsewhere, as the graph held them, pseudonymised (people
  # and company; titles, employers' shape and sources kept): sourced names and
  # employers, titles where the page gave one, no location, no email.
  defp person(id, facts, url \\ "https://www.bastion-security.example/company/leadership") do
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
      person(1, %{
        "name" => "Gavin Presto",
        "title" => "CISO",
        "employer" => "bastion-security.example"
      }),
      person(2, %{
        "name" => "Dana Smolen",
        "title" => "CFO",
        "employer" => "bastion-security.example"
      }),
      person(3, %{
        "name" => "Dorian Kest",
        "title" => "CEO & Founder",
        "employer" => "bastion-security.example"
      }),
      person(4, %{
        "name" => "Rupert C. Oland",
        "title" => "Director",
        "employer" => "bastion-security.example"
      }),
      person(5, %{"name" => "Anselm Hart", "employer" => "bastion-security.example"}),
      person(
        6,
        %{"name" => "Silvio Varda", "title" => "CEO ORBITSEC SPA"},
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
    # Every person fails the role check; Varda also has no employer.
    assert selection.rejected_by.role == 6
    assert selection.rejected_by.employer == 1
    assert selection.rejected_by.name == 0
  end

  test "each rejected person is recorded with their name, title, employer and failed checks" do
    target = campaign(%{roles: ["technology leaders"], titles: ["CTO", "CISO"]})

    {_ranked, selection} = Neuron.Selection.select(people(), target, [], @opts)

    assert length(selection.rejected_people) == selection.rejected

    by_name = Map.new(selection.rejected_people, &{&1.name, &1})

    assert %{
             title: "Director",
             employer: "bastion-security.example",
             checks: [:role],
             person_id: "person-4"
           } =
             by_name["Rupert C. Oland"]

    assert %{title: nil, checks: [:role]} = by_name["Anselm Hart"]
    assert %{employer: nil, checks: [:employer, :role]} = by_name["Silvio Varda"]
    refute Map.has_key?(by_name, "Gavin Presto")
  end

  test "expanded titles match whole words in a title, never a substring of another word" do
    target = campaign(%{roles: ["technology leaders"], titles: ["CTO", "CISO"]})

    {ranked, selection} = Neuron.Selection.select(people(), target, [], @opts)

    assert Enum.map(ranked, & &1.person_name) == ["Gavin Presto"]
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
