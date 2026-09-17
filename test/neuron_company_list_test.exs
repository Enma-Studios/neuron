defmodule Neuron.CompanyListTest do
  use ExUnit.Case, async: false

  # A host-supplied company list, as a host sends it: a URL, a www host, and
  # the same company twice.
  @companies "test/fixtures/companies/company_list.json" |> File.read!() |> Jason.decode!()

  @answers %{
    url: "https://nyx-labs.org/",
    organization: "Nyx Labs",
    field: "Security",
    offer: "Offensive security assessments",
    target_roles: "CTOs and VPs of Engineering",
    target_organizations: "Software product companies",
    lead_count: 5
  }

  defmodule SilentModel do
    def complete(messages, _opts) do
      send(self(), {:model_called, List.last(messages).content})
      {:error, :no_model_in_this_test}
    end
  end

  test "a supplied company list becomes the campaign's companies, as registrable domains in order" do
    assert {:ok, campaign} =
             Neuron.Campaign.normalize_campaign(Map.put(@answers, :companies, @companies))

    assert campaign.companies == ["quillmark.example", "ledgerwell.example"]
  end

  test "an entry that is not a company domain is rejected, naming it" do
    assert {:error, {:invalid_company, "Ledgerwell"}} =
             Neuron.Campaign.normalize_campaign(
               Map.put(@answers, :companies, ["quillmark.example", "Ledgerwell"])
             )
  end

  defp campaign do
    {:ok, campaign} =
      Neuron.Campaign.normalize_campaign(Map.put(@answers, :companies, @companies))

    campaign
  end

  # What :prepare hands on, with no titles to expand so no model is called.
  defp data do
    {:ok, data} =
      Neuron.CampaignPipeline.stage(
        :prepare,
        put_in(campaign(), [:target_profile, :roles], []),
        []
      )

    data
  end

  test "with a company list, planning search goes straight to the people-page step, with no search" do
    assert {:goto, :people_pages, data} =
             Neuron.CampaignPipeline.stage(:plan_search, data(), model_provider: SilentModel)

    refute_received {:model_called, _}
    assert data.searches == []
  end

  test "the people-page step starts each listed company at its home page, in list order" do
    assert {:goto, :dispatch, data} = Neuron.CampaignPipeline.stage(:people_pages, data(), [])

    assert Enum.map(data.pending_children, & &1.source.url) == [
             "https://quillmark.example",
             "https://ledgerwell.example"
           ]
  end

  defmodule Browser do
    # The listed companies' rebuilt pages; every other path is a 404 that
    # names nobody, as ledgerwell.example's people paths are.
    def fetch(url, _opts) do
      page =
        case url do
          "https://quillmark.example" -> "quillmark-home"
          "https://quillmark.example/team" -> "quillmark-team"
          "https://ledgerwell.example" -> "ledgerwell-home"
          _ -> nil
        end

      html =
        if page,
          do: File.read!("test/fixtures/people_pages/#{page}.html"),
          else: "<html><body><h1>Page not found</h1><p>Sorry, nothing here.</p></body></html>"

      {:ok, %{html: html, title: "Page"}}
    end
  end

  defmodule Model do
    def complete(messages, _opts) do
      prompt = List.last(messages).content
      send(self(), {:model_called, prompt})

      json =
        cond do
          prompt =~ "Expand the target roles" ->
            %{titles: ["CTO", "VP of Engineering"]}

          prompt =~ "Plan the next round" or prompt =~ "Harvest prospective buyer leads" ->
            raise "a company-list run must not search"

          prompt =~ "Summarize why" ->
            ids = Regex.scan(~r/person_id: "([^"]+)"/, prompt, capture: :all_but_first)

            %{
              summary: "Named engineering leaders from the supplied companies",
              leads:
                for(
                  [id] <- Enum.uniq(ids),
                  do: %{
                    person_id: id,
                    reason: "Named on the company's own team page",
                    channel: "email",
                    subject: "Security assessments",
                    body: "A short note about offensive security assessments."
                  }
                )
            }

          prompt =~ "Source: https://quillmark.example/team" ->
            %{claims: quillmark_team_claims()}

          true ->
            %{claims: []}
        end

      {:ok, %{"choices" => [%{"message" => %{"content" => Jason.encode!(json)}}]}}
    end

    defp quillmark_team_claims do
      for {name, title} <- [
            {"Aldo Veskari", "Chief R&D Officer and co-founder"},
            {"Mira Talvik", "CTO"},
            {"Tobin Draszek", "VP of Engineering"}
          ],
          {predicate, value, excerpt} <- [
            {"name", name, "### #{name}"},
            {"title", title, title},
            {"employer", "quillmark.example", "### #{name}"}
          ] do
        claim(name, predicate, value, excerpt)
      end ++
        [
          claim(
            "Mira Talvik",
            "email",
            "mira.talvik@quillmark.example",
            "mira.talvik@quillmark.example"
          )
        ]
    end

    defp claim(name, predicate, value, excerpt) do
      %{
        entity_type: "Person",
        identity: name,
        predicate: predicate,
        value: value,
        excerpt: excerpt,
        source_url: "https://quillmark.example/team"
      }
    end
  end

  describe "a company-list run" do
    @describetag :integration

    setup do
      connection = Neuron.Dgraph.connection()
      assert is_pid(connection), "integration requires a configured Dgraph connection"
      {:ok, _} = Neuron.Graph.Schema.apply(connection)
      :ok
    end

    defp run_company_list do
      {:ok, id} =
        Neuron.start_run(Neuron.Coordinator.Campaign, %{approved_campaign: campaign()},
          model_provider: Model,
          adapter: Browser,
          require_contact_channel: false
        )

      drain(id)
    end

    test "reads the listed companies' people pages and ranks their named leaders, without searching" do
      run = run_company_list()

      assert run.status == :complete,
             inspect(Map.take(run, [:error, :exhausted, :stage_index]), printable_limit: 2000)

      refute_received {:model_called, "Plan the next round" <> _}

      people_pages = run.result.people_pages
      assert people_pages["quillmark.example"].found == "https://quillmark.example/team"
      assert people_pages["ledgerwell.example"].found == nil
      assert people_pages["ledgerwell.example"].probes == 3

      names = Enum.map(run.result.leads, & &1.person_name)
      assert "Mira Talvik" in names
      assert "Tobin Draszek" in names
      refute "Aldo Veskari" in names
      assert run.result.stop_reason in [:companies_exhausted, :target_met]
    end

    # neureni#349: the host keeps a capture of each page behind a claim or an
    # address and checks every excerpt against its bytes.
    test "carries the retained page behind every claim and contact channel, and no other page" do
      run = run_company_list()
      assert run.status == :complete, inspect(Map.take(run, [:error, :stage_index]))

      leads = run.result.leads
      captures = run.result.captures

      # The home pages were read and backed nothing, so only the team page.
      assert Enum.map(captures, & &1.url) == ["https://quillmark.example/team"]

      for capture <- captures do
        assert capture.content_hash ==
                 Base.encode16(:crypto.hash(:sha256, capture.markdown), case: :lower)

        assert {:ok, _, _} = DateTime.from_iso8601(capture.retrieved_at)
      end

      pages = Map.new(captures, &{&1.content_hash, &1})

      mira = Enum.find(leads, &(&1.person_name == "Mira Talvik"))

      assert [%{kind: "email", value: "mira.talvik@quillmark.example"} = channel] =
               mira.contact_channels

      claims =
        Enum.flat_map(leads, fn lead ->
          lead.evidence ++ Enum.flat_map(lead.contact_channels, & &1.evidence)
        end)

      assert Enum.any?(claims, &(&1["predicate"] == "email"))

      for claim <- claims do
        page = Map.fetch!(pages, claim["content_hash"])
        assert page.url == claim["url"]
        assert :binary.match(page.markdown, claim["excerpt"]) != :nomatch
      end

      for url <- channel.evidence_urls, do: assert(Enum.any?(captures, &(&1.url == url)))
      assert :binary.match(hd(captures).markdown, channel.value) != :nomatch
    end
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
