defmodule Neuron.PeoplePagesTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Neuron.PeoplePages

  # Run ea7f7407 (#84) read contact pages. lumenglobal.io's names six roles
  # and no people, and the site has no page that names anyone: every people
  # path 404s. Another of the run's companies links "Meet the team" from its
  # contact page, and that page names its leaders with titles; its pages are
  # rebuilt with a pseudonymous company and people, titles and links kept.
  # lumenglobal.io's pages name nobody and are kept as captured.
  @lumen_url "https://lumenglobal.io/contact-us"
  @lumen_markdown File.read!("test/fixtures/people_pages/lumenglobal-contact-us.md")
  # The six role claims the run extracted from that page, as the graph held
  # them, each re-keyed by a stable fixture identity.
  @lumen_claims "test/fixtures/people_pages/ea7f7407_lumenglobal_claims.json"
                |> File.read!()
                |> Jason.decode!()

  @quillmark_contact "https://quillmark.example/contact"
  @quillmark_team "https://quillmark.example/team"

  def markdown(fixture, url) do
    {:ok, snapshot} =
      Neuron.Snapshot.from_html(File.read!("test/fixtures/people_pages/#{fixture}.html"), %{
        url: url
      })

    snapshot.markdown
  end

  describe "people links" do
    test "a company page's links to its people pages are found, in page order" do
      assert PeoplePages.links(
               @quillmark_contact,
               markdown("quillmark-contact", @quillmark_contact)
             ) ==
               ["https://quillmark.example/team", "https://quillmark.example/about-us"]
    end

    test "a page with no people links gives none" do
      assert PeoplePages.links(@lumen_url, @lumen_markdown) == []
    end
  end

  describe "a role with no name" do
    test "is a company role signal, not a person" do
      document = %{url: @lumen_url, markdown: @lumen_markdown}
      {:ok, claims} = Neuron.Knowledge.validate_claims(%{"claims" => @lumen_claims}, document)

      {kept, signals} = Neuron.Knowledge.role_signals(claims, document)

      refute Enum.any?(kept, &(&1.entity_type == "Person"))

      assert Enum.sort(Enum.map(signals, & &1.title)) == [
               "CEO",
               "COO",
               "Head of HR",
               "VP of Engineering (Backend)",
               "VP of Engineering (DevOps)",
               "VP of Engineering (FrontEnd)"
             ]

      for signal <- signals do
        assert signal.employer == "lumenglobal.io"
        assert signal.source_url == @lumen_url
      end
    end

    test "is never considered, and is recorded as a role signal" do
      now = DateTime.to_iso8601(DateTime.utc_now())

      nameless = %{
        "uid" => "0x1",
        "external_id" => "person-vp",
        "assertions" =>
          for {predicate, value} <- %{
                "title" => "VP of Engineering (DevOps)",
                "employer" => "lumenglobal.io"
              } do
            %{
              "uid" => "0x1#{predicate}",
              "predicate" => predicate,
              "claim_value" => value,
              "excerpt" => value,
              "url" => @lumen_url,
              "observed_at" => now,
              "authority" => 1.0,
              "assertion_kind" => "observed"
            }
          end
      }

      campaign = %{
        seller_profile: %{domain: "nyx-labs.org", offer: "security"},
        target_profile: %{
          markets: [],
          roles: ["VP of Engineering"],
          geography: [],
          exclusions: []
        }
      }

      {[], selection} =
        Neuron.Selection.select([nameless], campaign, [], require_contact_channel: false)

      assert selection.considered == 0
      assert selection.rejected_by.name == 0

      assert selection.role_signals == [
               %{
                 employer: "lumenglobal.io",
                 title: "VP of Engineering (DevOps)",
                 source_url: @lumen_url
               }
             ]
    end
  end

  # A finished ingestion child, as collect leaves it.
  defp child(url, result) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Neuron.FSM.create(
        Neuron.Run,
        %{
          profile: Neuron.Ingestion,
          input: %{url: url},
          opts: [],
          result:
            Map.merge(
              %{source_url: url, named_people: 0, people_links: [], role_signals: []},
              result
            ),
          error: nil
        },
        id: id
      )

    Neuron.Persistence.repo().update_all(
      from(m in Neuron.FSM.Machine, where: m.id == ^id),
      set: [state: "complete"]
    )

    %{id: id, source: %{url: url}}
  end

  defp data(children, urls, state \\ %{}) do
    %{
      campaign: %{seller_profile: %{domain: "nyx-labs.org"}},
      round: 1,
      searches: [],
      urls: urls,
      children: children,
      pending_children: children,
      failures: [],
      leads: [],
      started_at: DateTime.utc_now(),
      people_pages: state,
      role_signals: []
    }
  end

  defp urls_of(data), do: Enum.map(data.pending_children, & &1.source.url)

  test "each company's people page is found by the named people it yields, within a per-company cap" do
    signals = [%{employer: "lumenglobal.io", title: "CEO", source_url: @lumen_url}]

    first = [
      child(@lumen_url, %{role_signals: signals}),
      child(@quillmark_contact, %{
        people_links: ["https://quillmark.example/team", "https://quillmark.example/about-us"]
      })
    ]

    fetched = [@lumen_url, @quillmark_contact]

    # Neither contact page named anyone. quillmark.example's own link to its
    # team page is tried first; lumenglobal.io links none, so the common
    # paths are tried on its host.
    assert {:goto, :dispatch, next} =
             Neuron.CampaignPipeline.stage(:people_pages, data(first, fetched),
               people_page_attempts: 3
             )

    assert Enum.sort(urls_of(next)) == [
             "https://lumenglobal.io/team",
             "https://quillmark.example/team"
           ]

    assert next.role_signals == signals

    # quillmark.example/team names three people: found, and never probed again.
    # lumenglobal.io/team is a 404 that names nobody: not a hit.
    second = [
      child("https://quillmark.example/team", %{named_people: 3}),
      child("https://lumenglobal.io/team", %{})
    ]

    fetched = fetched ++ urls_of(next)

    assert {:goto, :dispatch, next} =
             Neuron.CampaignPipeline.stage(
               :people_pages,
               data(second, fetched, next.people_pages),
               people_page_attempts: 3
             )

    assert urls_of(next) == ["https://lumenglobal.io/about"]

    third = [child("https://lumenglobal.io/about", %{})]
    fetched = fetched ++ urls_of(next)

    assert {:goto, :dispatch, next} =
             Neuron.CampaignPipeline.stage(
               :people_pages,
               data(third, fetched, next.people_pages),
               people_page_attempts: 3
             )

    assert urls_of(next) == ["https://lumenglobal.io/about-us"]

    # Three probes and nobody named: lumenglobal.io is done, and the run
    # moves on to rank with what it has.
    fourth = [child("https://lumenglobal.io/about-us", %{})]
    fetched = fetched ++ urls_of(next)

    assert {:ok, done} =
             Neuron.CampaignPipeline.stage(
               :people_pages,
               data(fourth, fetched, next.people_pages),
               people_page_attempts: 3
             )

    assert done.people_pages["quillmark.example"].found == "https://quillmark.example/team"
    assert done.people_pages["quillmark.example"].probes == 1
    assert done.people_pages["lumenglobal.io"].found == nil
    assert done.people_pages["lumenglobal.io"].probes == 3
  end

  test "companies from anywhere can be given, not only those search found" do
    assert {:goto, :dispatch, next} =
             Neuron.CampaignPipeline.stage(:people_pages, data([], []),
               companies: ["quillmark.example"],
               people_page_attempts: 3
             )

    # Nothing has been read from it yet, so it starts at its home page.
    assert urls_of(next) == ["https://quillmark.example"]
  end

  defmodule Model do
    # Claims shaped as extraction returns them for each fixture page: the
    # run's own nameless roles for lumenglobal.io, and quillmark.example's
    # leaders by name on its own team page.
    def complete(messages, _opts) do
      [_, url] = Regex.run(~r/^Source: (\S+)$/m, List.last(messages).content)

      claims =
        case url do
          "https://lumenglobal.io" <> _ ->
            "test/fixtures/people_pages/ea7f7407_lumenglobal_claims.json"
            |> File.read!()
            |> Jason.decode!()

          "https://quillmark.example/team" ->
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
              %{
                "entity_type" => "Person",
                "identity" => name,
                "predicate" => predicate,
                "value" => value,
                "excerpt" => excerpt,
                "source_url" => url
              }
            end
        end

      {:ok,
       %{"choices" => [%{"message" => %{"content" => Jason.encode!(%{"claims" => claims})}}]}}
    end
  end

  defmodule Browser do
    def fetch(url, _opts) do
      html =
        case url do
          "https://quillmark.example/team" -> "quillmark-team"
        end

      {:ok, %{html: File.read!("test/fixtures/people_pages/#{html}.html"), title: "Team"}}
    end
  end

  describe "ingesting a company page" do
    @describetag :integration

    setup do
      connection = Neuron.Dgraph.connection()
      assert is_pid(connection), "integration requires a configured Dgraph connection"
      {:ok, _} = Neuron.Graph.Schema.apply(connection)
      :ok
    end

    defp ingest(source) do
      {:ok, id} = Neuron.Ingestion.submit(source, adapter: Browser, model_provider: Model)
      for _ <- 1..6, do: Oban.drain_queue(Neuron.Oban, queue: :agents)
      assert %{status: :complete, result: result} = Neuron.get_run(id)
      result
    end

    test "lumenglobal.io's contact page yields no people, and its six roles as signals" do
      result =
        ingest(%{
          url: @lumen_url,
          title: "Contact Us",
          markdown: @lumen_markdown,
          fetched_at: DateTime.utc_now()
        })

      assert result.named_people == 0
      assert length(result.role_signals) == 6
      assert result.people_links == []

      {:ok, %{"people" => people}} =
        Neuron.Graph.query(
          ~s|{ people(func: type(Person)) @filter(eq(title, "VP of Engineering (DevOps)")) { uid } }|
        )

      assert people == []
    end

    test "quillmark.example's team page yields its named people" do
      result = ingest(%{url: @quillmark_team})

      assert result.named_people == 3
      assert result.role_signals == []
    end
  end
end
