defmodule Neuron.LeadershipPeopleTest do
  use ExUnit.Case, async: false

  # The three company-published leadership pages run 92450aed ingested and got
  # no people from (#67). Captured after the run, since the host's graph had
  # been reset; each still names its leaders without linking a profile.
  @pages %{
    "https://atlastravel.com/company/leadership" => %{
      fixture: "atlastravel",
      employer: "atlastravel.com",
      people: [
        {"Elaine Osgood", "Chief Executive Officer", "Elaine Osgood, Chief Executive Officer"},
        {"Lea Cahill", "President", "Lea Cahill, President"},
        {"Andy Piggott", "Chief Information Officer", "Andy Piggott, Chief Information Officer"},
        {"Rashi Gujral", "Chief Financial Officer", "Rashi Gujral, Chief Financial Officer"}
      ]
    },
    "https://careers.booking.com/teams/leadership" => %{
      fixture: "booking-careers",
      employer: "booking.com",
      people: [
        {"Rob Francis", "Chief Technology Officer", "Rob Francis, our Chief Technology Officer"},
        {"Glenn Fogel", "President & Chief Executive Officer",
         "Glenn Fogel, President & Chief Executive Officer"}
      ]
    },
    "https://www.bookingholdings.com/about/leadership" => %{
      fixture: "bookingholdings",
      employer: "bookingholdings.com",
      people: [
        {"Glenn Fogel", "Chief Executive Officer and President",
         "**Glenn Fogel** has served as our Chief Executive Officer and President"},
        {"Ewout Steenbergen", "Executive Vice President and Chief Financial Officer",
         "**Ewout Steenbergen** has been our Executive Vice President and Chief Financial Officer"},
        {"Paulo Pisano", "Chief Human Resources Officer",
         "**Paulo Pisano** has served as our Chief Human Resources Officer"}
      ]
    }
  }

  defp html(url), do: File.read!("test/fixtures/leadership/#{@pages[url].fixture}.html")

  defp markdown(url) do
    {:ok, snapshot} = Neuron.Snapshot.from_html(html(url), %{url: url})
    snapshot.markdown
  end

  # Claims as the model is now asked to return them for a leadership page:
  # each person identified by their name as written, with an employer claim
  # naming the organization, and no profile URL.
  def claims(url, page \\ nil) do
    page = page || @pages[url]

    for {name, title, excerpt} <- page.people,
        {predicate, value} <- [{"name", name}, {"title", title}, {"employer", page.employer}] do
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

  defp document(url), do: %{url: url, markdown: markdown(url)}

  defp people(kept) do
    kept
    |> Enum.filter(&(&1.entity_type == "Person"))
    |> Enum.group_by(&Neuron.Knowledge.entity_id("Person", &1.identity))
    |> Enum.map(fn {_id, claims} -> Map.new(claims, &{&1.predicate, &1.value}) end)
  end

  test "each leadership page yields its named people with titles, without a profile URL" do
    for {url, page} <- @pages do
      assert {:ok, kept} =
               Neuron.Knowledge.validate_claims(%{"claims" => claims(url)}, document(url))

      found = people(kept)
      assert length(found) == length(page.people), "#{url}: #{inspect(found)}"

      for {name, title, _excerpt} <- page.people do
        assert %{"title" => ^title, "employer" => employer} =
                 Enum.find(found, &(&1["name"] == name)),
               "#{url}: #{name}"

        assert employer == page.employer
      end
    end
  end

  test "a person named on a page their employer does not own is still dropped" do
    # Names in a listicle are not the employer speaking for itself.
    url = "https://thefinancialtechnologyreport.com/top-financial-technology-ceos-of-2025"
    page = %{employer: "booking.com", people: [{"Glenn Fogel", "CEO", "Glenn Fogel, CEO"}]}

    assert {:ok, []} =
             Neuron.Knowledge.validate_claims(
               %{"claims" => claims(url, page)},
               %{url: url, markdown: "Glenn Fogel, CEO of Booking.com"}
             )
  end

  defmodule Browser do
    def fetch(url, _opts) do
      name =
        case url do
          "https://atlastravel.com" <> _ -> "atlastravel"
          "https://careers.booking.com" <> _ -> "booking-careers"
          "https://www.bookingholdings.com" <> _ -> "bookingholdings"
        end

      {:ok, %{html: File.read!("test/fixtures/leadership/#{name}.html"), title: "Leadership"}}
    end
  end

  defmodule Model do
    def complete(messages, _opts) do
      [_, url] = Regex.run(~r/^Source: (\S+)$/m, List.last(messages).content)
      claims = Neuron.LeadershipPeopleTest.claims(url)

      {:ok,
       %{"choices" => [%{"message" => %{"content" => Jason.encode!(%{"claims" => claims})}}]}}
    end
  end

  describe "ingesting a leadership page" do
    @describetag :integration

    setup do
      connection = Neuron.Dgraph.connection()
      assert is_pid(connection), "integration requires a configured Dgraph connection"
      {:ok, _} = Neuron.Graph.Schema.apply(connection)
      :ok
    end

    test "creates each named person, sourced to the page, at own-site authority" do
      url = "https://atlastravel.com/company/leadership"
      {:ok, id} = Neuron.Ingestion.submit(%{url: url}, adapter: Browser, model_provider: Model)

      for _ <- 1..6, do: Oban.drain_queue(Neuron.Oban, queue: :agents)
      assert %{status: :complete} = Neuron.get_run(id)

      {:ok, %{"people" => people}} =
        Neuron.Graph.query(
          ~s|{ people(func: type(Person)) @filter(eq(name, "Elaine Osgood") OR eq(name, "Lea Cahill") OR eq(name, "Andy Piggott") OR eq(name, "Rashi Gujral")) { name title employer { domain } assertions { predicate url authority } } }|
        )

      assert Enum.sort(Enum.map(people, & &1["name"])) ==
               ["Andy Piggott", "Elaine Osgood", "Lea Cahill", "Rashi Gujral"]

      for person <- people do
        assert person["title"] != nil
        assert person["employer"]["domain"] == "atlastravel.com"

        for assertion <- person["assertions"] do
          assert assertion["url"] == url
          assert assertion["authority"] == 1.0
        end
      end
    end
  end
end
