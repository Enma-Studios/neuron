defmodule Neuron.SelectionTest do
  use ExUnit.Case, async: false

  test "semantic similarity contributes to fuzzy fit but cannot bypass contact qualification" do
    now = DateTime.utc_now()

    campaign = %{
      seller_profile: %{domain: "seller.example"},
      target_profile: %{
        markets: ["security automation"],
        roles: ["CTO"],
        geography: ["UK"],
        exclusions: []
      }
    }

    attrs = %{
      "name" => "Ada",
      "title" => "CTO",
      "location" => "UK",
      "employer" => "buyer.example",
      "email" => "ada@buyer.example"
    }

    claims =
      for {key, value} <- attrs,
          do: %{
            "predicate" => key,
            "claim_value" => value,
            "excerpt" => value,
            "observed_at" => DateTime.to_iso8601(now),
            "url" => "https://buyer.example/team",
            "authority" => 1.0
          }

    record = %{
      "uid" => "0x123",
      "external_id" => "person",
      "embedding" => [1.0, 0.0],
      "assertions" => claims
    }

    matched = Neuron.Selection.score(record, campaign, [1.0, 0.0])
    unrelated = Neuron.Selection.score(record, campaign, [0.0, 1.0])
    assert matched.fit_score > unrelated.fit_score
    assert matched.score_breakdown.market > 0

    assert Neuron.Selection.score(
             Map.put(record, "assertions", Enum.reject(claims, &(&1["predicate"] == "email"))),
             campaign,
             [1.0, 0.0]
           ) == nil

    refute Neuron.Selection.company_email?("info@buyer.example", "buyer.example")
    refute Neuron.Selection.company_email?("ada@gmail.com", "buyer.example")
    refute Neuron.Selection.company_email?("ada@buyer.example.evil.test", "buyer.example")

    social_record =
      record
      |> Map.put("profile_url", "https://linkedin.com/in/ada")
      |> Map.put(
        "assertions",
        [
          %{
            "predicate" => "profile_url",
            "claim_value" => "https://linkedin.com/in/ada",
            "excerpt" => "https://linkedin.com/in/ada",
            "observed_at" => DateTime.to_iso8601(now),
            "url" => "https://buyer.example/team",
            "authority" => 1.0
          }
          | Enum.reject(claims, &(&1["predicate"] == "email"))
        ]
      )

    social = Neuron.Selection.score(social_record, campaign, [1.0, 0.0])
    assert social.email == nil
    assert social.preferred_channel == "linkedin"
    assert matched.contact_priority > social.contact_priority

    assert {:ok, drafted} =
             Neuron.Outreach.confirm(
               %{
                 "channel" => "linkedin",
                 "reason" => "Verified CTO",
                 "body" =>
                   "Ada, your engineering work looks relevant to our security research. Open to connecting?"
               },
               social
             )

    assert drafted.email_body == nil
    assert drafted.outreach.channel == "linkedin"

    assert {:error, _} =
             Neuron.Outreach.confirm(
               %{
                 "channel" => "email",
                 "reason" => "CTO",
                 "subject" => "Hello",
                 "body" => "Hello"
               },
               social
             )

    assert {:error, _} =
             Neuron.Outreach.confirm(
               %{
                 "channel" => "linkedin",
                 "reason" => "CTO",
                 "body" => String.duplicate("x", 301)
               },
               social
             )

    assert Neuron.Selection.score(
             social_record
             |> Map.put("profile_url", "https://github.com/ada")
             |> Map.update!("assertions", fn assertions ->
               Enum.map(assertions, fn
                 %{"predicate" => "profile_url"} = claim ->
                   Map.merge(claim, %{
                     "claim_value" => "https://github.com/ada",
                     "excerpt" => "https://github.com/ada"
                   })

                 claim ->
                   claim
               end)
             end),
             campaign,
             [1.0, 0.0]
           ) == nil
  end

  test "an alternate approved role and geography are full eligibility matches" do
    campaign = %{
      seller_profile: %{domain: "seller.example"},
      target_profile: %{
        markets: [],
        roles: ["CISO", "CTO", "Head of Security"],
        geography: ["Nepal", "India", "Bangladesh"],
        exclusions: []
      }
    }

    now = DateTime.to_iso8601(DateTime.utc_now())

    claims =
      for {predicate, value} <- %{
            "name" => "Asha",
            "title" => "CTO",
            "location" => "India",
            "employer" => "buyer.example",
            "email" => "asha@buyer.example"
          },
          do: %{
            "predicate" => predicate,
            "claim_value" => value,
            "excerpt" => value,
            "url" => "https://buyer.example/team",
            "observed_at" => now,
            "authority" => 1.0
          }

    lead =
      Neuron.Selection.score(
        %{
          "uid" => "0x456",
          "external_id" => "asha",
          "embedding" => [1.0],
          "assertions" => claims
        },
        campaign,
        [1.0]
      )

    assert lead.score_breakdown.role == 1.0
    assert lead.score_breakdown.geography == 1.0
  end

  test "reservations suppress repeats per campaign and are idempotent for the owning run" do
    campaign = Ecto.UUID.generate()
    {:ok, run} = Neuron.start_run(Neuron.Coordinator.Default, %{})
    {:ok, second} = Neuron.start_run(Neuron.Coordinator.Default, %{})
    lead = %{person_id: Ecto.UUID.generate()}
    assert {:ok, [^lead]} = Neuron.Selection.reserve(campaign, run, [lead])
    assert {:ok, [^lead]} = Neuron.Selection.reserve(campaign, run, [lead])
    assert {:ok, []} = Neuron.Selection.reserve(campaign, second, [lead])
    assert {:ok, [^lead]} = Neuron.Selection.reserve(Ecto.UUID.generate(), second, [lead])
    assert :ok = Neuron.Selection.release(run)
    assert {:ok, [^lead]} = Neuron.Selection.reserve(campaign, second, [lead])
    assert :ok = Neuron.Selection.delivered(second)
    assert :ok = Neuron.Selection.release(second)
    assert {:ok, []} = Neuron.Selection.reserve(campaign, run, [lead])
  end
end
