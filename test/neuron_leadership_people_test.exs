defmodule Neuron.LeadershipPeopleTest do
  use ExUnit.Case, async: false

  # The three company-published leadership pages run 92450aed ingested and got
  # no people from (#67), rebuilt with pseudonymous people and companies:
  # each keeps the shape its page named leaders in (image alt text, prose,
  # bold names before a bio) and their titles, and links no profile.
  @pages %{
    "https://meridiantravel.example/company/leadership" => %{
      fixture: "meridiantravel",
      employer: "meridiantravel.example",
      people: [
        {"Elise Ormond", "Chief Executive Officer", "Elise Ormond, Chief Executive Officer"},
        {"Lena Carrow", "President", "Lena Carrow, President"},
        {"Anders Pell", "Chief Information Officer", "Anders Pell, Chief Information Officer"},
        {"Ravi Gunnar", "Chief Financial Officer", "Ravi Gunnar, Chief Financial Officer"}
      ]
    },
    "https://careers.harbourstay.example/teams/leadership" => %{
      fixture: "harbourstay-careers",
      employer: "harbourstay.example",
      people: [
        {"Rowan Fitch", "Chief Technology Officer", "Rowan Fitch, our Chief Technology Officer"},
        {"Graham Fennick", "President & Chief Executive Officer",
         "Graham Fennick, President & Chief Executive Officer"}
      ]
    },
    "https://www.harbourstayholdings.example/about/leadership" => %{
      fixture: "harbourstayholdings",
      employer: "harbourstayholdings.example",
      people: [
        {"Graham Fennick", "Chief Executive Officer and President",
         "**Graham Fennick** has served as our Chief Executive Officer and President"},
        {"Evert Sandler", "Executive Vice President and Chief Financial Officer",
         "**Evert Sandler** has been our Executive Vice President and Chief Financial Officer"},
        {"Petra Sollen", "Chief Human Resources Officer",
         "**Petra Sollen** has served as our Chief Human Resources Officer"}
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

    page = %{
      employer: "harbourstay.example",
      people: [{"Graham Fennick", "CEO", "Graham Fennick, CEO"}]
    }

    assert {:ok, []} =
             Neuron.Knowledge.validate_claims(
               %{"claims" => claims(url, page)},
               %{url: url, markdown: "Graham Fennick, CEO of Harbourstay"}
             )
  end

  defmodule Browser do
    def fetch(url, _opts) do
      name =
        case url do
          "https://meridiantravel.example" <> _ -> "meridiantravel"
          "https://careers.harbourstay.example" <> _ -> "harbourstay-careers"
          "https://www.harbourstayholdings.example" <> _ -> "harbourstayholdings"
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
      url = "https://meridiantravel.example/company/leadership"
      {:ok, id} = Neuron.Ingestion.submit(%{url: url}, adapter: Browser, model_provider: Model)

      for _ <- 1..6, do: Oban.drain_queue(Neuron.Oban, queue: :agents)
      assert %{status: :complete} = Neuron.get_run(id)

      {:ok, %{"people" => people}} =
        Neuron.Graph.query(
          ~s|{ people(func: type(Person)) @filter(eq(name, "Elise Ormond") OR eq(name, "Lena Carrow") OR eq(name, "Anders Pell") OR eq(name, "Ravi Gunnar")) { name title employer { domain } assertions { predicate url authority } } }|
        )

      assert Enum.sort(Enum.map(people, & &1["name"])) ==
               ["Anders Pell", "Elise Ormond", "Lena Carrow", "Ravi Gunnar"]

      for person <- people do
        assert person["title"] != nil
        assert person["employer"]["domain"] == "meridiantravel.example"

        for assertion <- person["assertions"] do
          assert assertion["url"] == url
          assert assertion["authority"] == 1.0
        end
      end
    end
  end
end
