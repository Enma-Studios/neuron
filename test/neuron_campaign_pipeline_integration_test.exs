defmodule Neuron.CampaignPipelineIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  defmodule Browser do
    def fetch(url, opts) do
      domain = opts[:fixture_domain]

      if String.contains?(url, "duckduckgo.com") do
        {:ok,
         %{
           html: "<a class=\"result__a\" href=\"https://#{domain}/team\">Team</a>",
           title: "Search"
         }}
      else
        {:ok,
         %{
           html:
             "<p>Ada is CTO of #{domain} in #{opts[:fixture_location]}. ada@#{domain}. https://linkedin.com/in/#{domain}</p>",
           title: "Team"
         }}
      end
    end
  end

  defmodule PageAgent do
    def run_page(_handle, task, opts) do
      domain = opts[:fixture_domain]
      profile = "https://linkedin.com/in/#{domain}"

      links =
        cond do
          String.contains?(task.url, "linkedin.com") ->
            [%{href: profile, label: "Jane Founder — CTO at #{domain}"}]

          String.contains?(task.url, "duckduckgo.com") ->
            [%{href: "https://#{domain}/team", label: "Team"}]

          true ->
            []
        end

      {:ok,
       %{
         url: task.url,
         title: "Search",
         text: "Results for #{task.query}",
         links: links,
         engine: task.engine,
         query: task.query
       }}
    end
  end

  defmodule Model do
    def complete(messages, opts) do
      prompt = List.last(messages).content
      domain = opts[:fixture_domain]
      profile = "https://linkedin.com/in/#{domain}"

      json =
        cond do
          String.contains?(prompt, "Extract professional intelligence") ->
            values = %{
              name: "Ada",
              title: "CTO",
              employer: domain,
              email: "ada@#{domain}",
              location: opts[:fixture_location]
            }

            %{
              claims:
                Enum.map(values, fn {predicate, value} ->
                  %{
                    entity_type: "Person",
                    identity: profile,
                    predicate: to_string(predicate),
                    value: value,
                    excerpt: value,
                    source_url: "https://#{domain}/team"
                  }
                end)
            }

          String.contains?(prompt, "Expand the target roles") ->
            %{titles: ["CTO"]}

          String.contains?(prompt, "Plan the next round of platform-tailored searches") ->
            %{
              searches: [
                %{"engine" => "duckduckgo", "query" => "#{domain} leadership team"},
                %{"engine" => "linkedin", "query" => "#{domain} CTO founder"}
              ]
            }

          String.contains?(prompt, "Harvest prospective buyer leads") ->
            results =
              if String.contains?(prompt, "https://#{domain}/team") do
                [
                  %{
                    "title" => "Team",
                    "url" => "https://#{domain}/team",
                    "reason" => "buyer organization team page"
                  }
                ]
              else
                []
              end

            %{results: results}

          String.contains?(prompt, "Summarize why") ->
            %{
              summary: "One evidenced match",
              leads: [
                %{
                  person_id: Neuron.Knowledge.entity_id("Person", profile),
                  reason: "CTO with a sourced company email: https://#{domain}/team",
                  channel: "email",
                  subject: "Security for your team",
                  body: "Ada, can we discuss an assessment?"
                }
              ]
            }
        end

      {:ok, %{"choices" => [%{"message" => %{"content" => Jason.encode!(json)}}]}}
    end
  end

  test "campaign searches external prospects, checkpoints ingestion, returns graph leads and suppresses repeats" do
    {:ok, _} = Neuron.Graph.Schema.apply(Neuron.Dgraph.connection())
    nonce = Ecto.UUID.generate()
    domain = "buyer-#{nonce}.example"

    {:ok, campaign} =
      Neuron.Campaign.intake(%{
        organization: "seller.example",
        field: "Security",
        offer: "Security assessments",
        target_roles: ["CTO"],
        target_organizations: ["Software"],
        geography: [nonce],
        lead_count: 1
      })

    opts = [
      model_provider: Model,
      adapter: Browser,
      page_adapter: PageAgent,
      handles: [%{provider: :fake, session: nil}],
      fixture_domain: domain,
      fixture_location: nonce,
      max_rounds: 1
    ]

    {:ok, id} =
      Neuron.start_run(Neuron.Coordinator.Campaign, %{approved_campaign: campaign}, opts)

    run = drain(id)
    assert run.status == :complete
    assert run.result.status == :target_met
    assert [lead] = run.leads
    assert lead.email == "ada@#{domain}"
    assert lead.organization != campaign.seller_profile.domain
    assert lead.email_body != ""
    assert lead.semantic_similarity > 0
    assert run.result.campaign_id == campaign.campaign_id

    {:ok, next_id} =
      Neuron.start_run(Neuron.Coordinator.Campaign, %{approved_campaign: campaign}, opts)

    repeated = drain(next_id)
    assert repeated.result.status == :no_qualified_leads
    assert repeated.leads == []
  end

  defp drain(id, remaining \\ 80)
  defp drain(id, 0), do: flunk("campaign did not terminate: #{inspect(Neuron.get_run(id))}")

  defp drain(id, remaining) do
    case Neuron.get_run(id) do
      %{status: status} = run when status in [:complete, :failed, :cancelled] ->
        run

      _ ->
        Oban.drain_queue(Neuron.Oban, queue: :agents, with_scheduled: true)
        drain(id, remaining - 1)
    end
  end
end
