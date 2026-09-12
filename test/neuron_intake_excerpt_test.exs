defmodule Neuron.Campaign.IntakeExcerptTest do
  use ExUnit.Case, async: false

  # The real nyx-labs.org homepage, captured. The excerpts have to survive
  # Htmd, so a hand-written page would not test the thing that breaks.
  @html File.read!("test/fixtures/nyx-labs.html")
  @url "https://nyx-labs.org"

  # Quotes as a model really returns them: one copied exactly, one joined
  # across a heading break, one nowhere on the page.
  @sources %{
    "field" => "Offensive security · Defensive security · Security engineering",
    "offer" =>
      "Security that holds from every side. Nyx Labs finds where trust breaks, strengthens the systems around it",
    "geography" => "Nyx Labs is headquartered in Zurich, Switzerland."
  }

  defmodule Browser do
    def fetch(_url, _opts),
      do: {:ok, %{html: File.read!("test/fixtures/nyx-labs.html"), title: "Nyx Labs"}}
  end

  defmodule Model do
    @json ~s({
      "organization": "Nyx Labs",
      "domain": "nyx-labs.org",
      "field": "Security research and engineering",
      "offer": "Offensive and defensive security assessment, monitoring, and security engineering",
      "sources": {
        "field": "Offensive security · Defensive security · Security engineering",
        "offer": "Security that holds from every side. Nyx Labs finds where trust breaks, strengthens the systems around it",
        "geography": "Nyx Labs is headquartered in Zurich, Switzerland."
      }
    })

    def complete(_messages, _opts),
      do: {:ok, %{"choices" => [%{"message" => %{"content" => @json}}]}}
  end

  defp markdown do
    {:ok, snapshot} = Neuron.Snapshot.from_html(@html, %{url: @url})
    snapshot.markdown
  end

  defp intake do
    Neuron.Campaign.intake(
      %{url: @url, target_roles: ["CISO"], target_organizations: ["Fintech"], lead_count: 3},
      adapter: Browser,
      model_provider: Model
    )
  end

  test "field and offer each carry an excerpt that is byte-exact in the Markdown" do
    markdown = markdown()
    sources = Neuron.Campaign.field_sources(@sources, markdown, @url)

    for key <- [:field, :offer] do
      %{excerpt: excerpt, source_url: source_url} = sources[key]
      assert source_url == @url
      assert :binary.match(markdown, excerpt) != :nomatch, "#{key} excerpt is not in the Markdown"
    end
  end

  test "a quote that is only on the page with different whitespace is relocated" do
    sources = Neuron.Campaign.field_sources(@sources, markdown(), @url)

    # The model joined a heading and the paragraph under it, and typed the
    # heading's non-breaking spaces as ordinary ones. What comes back is the
    # page's own bytes, newlines and U+00A0 and all.
    excerpt = sources.offer.excerpt
    refute excerpt == @sources["offer"]
    assert excerpt =~ "\n"
    assert excerpt =~ "\u00A0"
    assert excerpt =~ "Nyx Labs finds where trust breaks"
    assert :binary.match(markdown(), excerpt) != :nomatch
  end

  test "a quote that is nowhere on the page is dropped, not returned as evidence" do
    sources = Neuron.Campaign.field_sources(@sources, markdown(), @url)
    refute Map.has_key?(sources, :geography)
  end

  test "no quotes at all is not an error" do
    assert Neuron.Campaign.field_sources(nil, markdown(), @url) == %{}
    assert Neuron.Campaign.field_sources(%{}, markdown(), @url) == %{}
  end

  # Intake saves the page to Dgraph before it extracts, so the whole chain
  # needs one, like every other test that reaches `save_document`.
  describe "intake" do
    @describetag :integration

    setup do
      connection = Neuron.Dgraph.connection()
      assert is_pid(connection), "integration requires a configured Dgraph connection"
      {:ok, _} = Neuron.Graph.Schema.apply(connection)
      :ok
    end

    test "returns the page's Markdown once, and excerpts anchored in it" do
      assert {:ok, campaign} = intake()

      assert campaign.source_markdown == markdown()
      assert campaign.source_url == @url

      for key <- [:field, :offer] do
        %{excerpt: excerpt, source_url: source_url} = campaign.field_sources[key]
        assert source_url == @url
        assert :binary.match(campaign.source_markdown, excerpt) != :nomatch
      end
    end

    test "summaries are unchanged; the excerpt is additional" do
      assert {:ok, campaign} = intake()

      assert campaign.field == "Security research and engineering"
      assert campaign.offer =~ "Offensive and defensive security"
      refute campaign.field == campaign.field_sources.field.excerpt
      refute Map.has_key?(campaign.field_sources, :geography)
    end
  end
end
