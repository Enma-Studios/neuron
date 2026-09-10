defmodule Neuron.ContactChannelTest do
  use ExUnit.Case, async: true

  # A person with a name, a title and an employer, all sourced, and no
  # observed email or professional profile anywhere.
  defp campaign do
    %{
      campaign_id: Ecto.UUID.generate(),
      lead_count: 1,
      seller_profile: %{domain: "seller.example", offer: "custom software"},
      target_profile: %{markets: ["software"], roles: ["CTO"], geography: [], exclusions: []}
    }
  end

  defp claim(predicate, value, now) do
    %{
      "predicate" => predicate,
      "claim_value" => value,
      "excerpt" => value,
      "observed_at" => DateTime.to_iso8601(now),
      "url" => "https://buyer.example/team",
      "authority" => 1.0,
      "assertion_kind" => "observed"
    }
  end

  defp unreachable_record do
    now = DateTime.utc_now()

    %{
      "uid" => "0x1",
      "external_id" => "person-without-a-channel",
      Neuron.Embedding.field() => [1.0, 0.0],
      "assertions" => [
        claim("name", "Ada Buyer", now),
        claim("title", "CTO", now),
        claim("employer", "buyer.example", now)
      ]
    }
  end

  test "by default a person with no observed channel is withheld" do
    assert Neuron.Selection.score(unreachable_record(), campaign(), [1.0, 0.0]) ==
             :no_contact_channel
  end

  test "under require_contact_channel: false the same person is returned with observed_email nil" do
    lead =
      Neuron.Selection.score(unreachable_record(), campaign(), [1.0, 0.0],
        require_contact_channel: false
      )

    assert lead.person_name == "Ada Buyer"
    assert lead.title == "CTO"
    assert lead.organization == "buyer.example"

    # No email was observed, so none is reported and none is invented.
    assert lead.observed_email == nil
    assert lead.email == nil
    assert lead.contact_channels == []
    assert lead.preferred_channel == nil

    # Everything else about the lead is unchanged.
    assert lead.fit_score > 0
    assert lead.score_breakdown.role == 1.0
    assert lead.evidence_urls == ["https://buyer.example/team"]
    assert length(lead.evidence) == 3

    # A lead with no channel never outranks one that has a way to reach it.
    assert lead.contact_priority == 0.0
  end

  test "an observed company email is still required to report one" do
    now = DateTime.utc_now()

    record =
      Map.update!(unreachable_record(), "assertions", fn claims ->
        [claim("email", "ada@buyer.example", now) | claims]
      end)

    lead =
      Neuron.Selection.score(record, campaign(), [1.0, 0.0], require_contact_channel: false)

    assert lead.observed_email == "ada@buyer.example"
    assert lead.preferred_channel == "email"
    assert [%{kind: "email", value: "ada@buyer.example"}] = lead.contact_channels
  end

  describe "the campaign summary separates the two ways of returning nothing" do
    test "no companies matched" do
      assert {:ok, %{summary: summary}} =
               Neuron.CampaignPipeline.stage(
                 :draft,
                 %{leads: [], withheld_contact: 0},
                 []
               )

      assert summary == "No companies matched the campaign criteria."
    end

    test "companies matched, no contact channel observed" do
      assert {:ok, %{summary: summary}} =
               Neuron.CampaignPipeline.stage(
                 :draft,
                 %{leads: [], withheld_contact: 3},
                 []
               )

      assert summary =~ "Companies matched"
      assert summary =~ "no contact channel was observed"
    end
  end

  test "a channel-less lead keeps its reason and carries no draft" do
    lead = %{
      person_id: "p1",
      contact_channels: [],
      preferred_channel: nil,
      observed_email: nil
    }

    assert {:ok, confirmed} =
             Neuron.Outreach.confirm(
               %{"person_id" => "p1", "reason" => "CTO at a company with no engineers"},
               lead
             )

    assert confirmed.reason == "CTO at a company with no engineers"
    assert confirmed.outreach == nil
    assert confirmed.email_subject == nil
    assert confirmed.email_body == nil
  end

  test "a channel-less lead with an invented channel still yields no recipient" do
    lead = %{person_id: "p1", contact_channels: [], preferred_channel: nil, observed_email: nil}

    assert {:ok, confirmed} =
             Neuron.Outreach.confirm(
               %{
                 "person_id" => "p1",
                 "reason" => "CTO",
                 "channel" => "email",
                 "body" => "Hello",
                 "subject" => "Hi"
               },
               lead
             )

    assert confirmed.outreach == nil
    assert confirmed.email_body == nil
  end

  test "a campaign result validates a lead that has no contact channel" do
    result = %{
      campaign_id: Ecto.UUID.generate(),
      campaign_run_id: Ecto.UUID.generate(),
      status: :partial,
      target_count: 2,
      returned_count: 1,
      summary: "One company matched with no observed contact channel.",
      stop_reason: :budget_exhausted,
      failures: [],
      campaign: %{},
      leads: [
        %{
          person_id: "p1",
          person_uid: "0x1",
          person_name: "Ada Buyer",
          organization: "buyer.example",
          title: "CTO",
          email: nil,
          observed_email: nil,
          contact_channels: [],
          preferred_channel: nil,
          contact_priority: 0.0,
          fit_score: 0.7,
          score_breakdown: %{},
          semantic_similarity: 0.5,
          evidence: [%{"predicate" => "title"}],
          evidence_urls: ["https://buyer.example/team"],
          reason: "CTO at a company with no engineers",
          outreach: nil
        }
      ]
    }

    assert {:ok, _} = Neuron.Schemas.validate_campaign_result(result)

    # An email that was never observed cannot be attached to the lead either.
    invented = put_in(result, [:leads, Access.at(0), :observed_email], "ada@buyer.example")
    assert {:error, _} = Neuron.Schemas.validate_campaign_result(invented)
  end
end
