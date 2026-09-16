defmodule Neuron.PeoplePages do
  @moduledoc """
  Finds each company's people page by what it yields.

  A campaign's search lands on whatever page a company has for its query,
  often a contact page, and a contact page names roles rather than people
  (#84). For every company it has reached, and for any company it is given,
  the campaign tries the pages that company links as its people pages, then
  the common people paths on its host, one page per pass. A page is a hit
  only when it produced named people: a path that answers and names nobody
  is not. Each company gets at most `:attempts` probes.

  State is a map of company domain to
  `%{found: url | nil, probes: count, tried: [url], links: [url]}`.
  """

  alias Neuron.Knowledge

  @paths ~w(/team /about /about-us /leadership /company/leadership /people /our-team /company/team /about/team /about/leadership /management /who-we-are)
  @segments ~w(team teams our-team the-team about about-us who-we-are leadership leaders people management founders staff)
  # Companies are the ones a page belongs to, never the platform it was
  # read on.
  @platforms ~w(linkedin.com x.com twitter.com facebook.com instagram.com youtube.com github.com medium.com substack.com crunchbase.com wikipedia.org reddit.com)

  @doc "Links on `url`'s page, in page order, to the same company's people pages."
  def links(url, markdown) when is_binary(url) and is_binary(markdown) do
    base = URI.parse(url)
    company = Knowledge.registrable_domain(url)
    own = Knowledge.canonical_url(url)

    Regex.scan(~r/\]\(([^)\s]+)/, markdown, capture: :all_but_first)
    |> Enum.flat_map(fn [href] -> resolve(base, href) end)
    |> Enum.filter(&people_url?(&1, company))
    |> Enum.map(&Knowledge.canonical_url/1)
    |> Enum.reject(&(&1 == own))
    |> Enum.uniq()
  end

  @doc "Whether a company domain is one whose own people pages are worth probing."
  def company?(domain), do: is_binary(domain) and domain not in @platforms

  @doc """
  Fold finished pages into the state: each page is tried for its company,
  its people links are remembered, and a page that named people is the
  company's people page.
  """
  def observe(state, results) do
    Enum.reduce(results, state, fn result, state ->
      url = result[:source_url]

      case url && Knowledge.registrable_domain(url) do
        nil ->
          state

        company ->
          url = Knowledge.canonical_url(url)
          entry = entry(state, company)

          entry = %{
            entry
            | tried: Enum.uniq(entry.tried ++ [url]),
              links: Enum.uniq(entry.links ++ (result[:people_links] || [])),
              found: entry.found || if((result[:named_people] || 0) > 0, do: url)
          }

          Map.put(state, company, entry)
      end
    end)
  end

  @doc """
  The next page to probe for each company that has no people page yet and
  probes left: its own people links first, then the common paths on its
  host, skipping anything tried or already fetched. A company with nothing
  read yet starts at its home page. Returns `{state, urls}`.
  """
  def next(state, companies, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 3)
    fetched = MapSet.new(Enum.map(Keyword.get(opts, :fetched, []), &Knowledge.canonical_url/1))

    Enum.reduce(companies, {state, []}, fn company, {state, urls} ->
      entry = entry(state, company)

      host =
        case entry.tried do
          [first | _] -> URI.parse(first).host
          [] -> company
        end

      # A company nothing has been read from yet starts at its home page,
      # which names its people or links the page that does.
      home = if entry.tried == [], do: ["https://#{host}"], else: []

      candidate =
        Enum.find(
          home ++ entry.links ++ Enum.map(@paths, &"https://#{host}#{&1}"),
          &(&1 not in entry.tried and not MapSet.member?(fetched, &1))
        )

      if entry.found || entry.probes >= attempts || is_nil(candidate) do
        {Map.put(state, company, entry), urls}
      else
        probed = %{entry | probes: entry.probes + 1, tried: entry.tried ++ [candidate]}
        {Map.put(state, company, probed), urls ++ [candidate]}
      end
    end)
  end

  defp entry(state, company),
    do: Map.get(state, company, %{found: nil, probes: 0, tried: [], links: []})

  defp resolve(base, href) do
    [base |> URI.merge(href) |> URI.to_string()]
  rescue
    _ -> []
  end

  defp people_url?(url, company) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and Knowledge.registrable_domain(url) == company and
      Enum.any?(
        String.split(uri.path || "", "/", trim: true),
        &(String.downcase(&1) in @segments)
      )
  end
end
