defmodule Neuron.Search.Harvest do
  @moduledoc """
  Model-side processing of page transcripts into search results.

  Each transcript produced by a page sub-agent is read by the model, which
  picks the URLs worth ingesting as prospect evidence. Every harvested URL
  must literally appear in the transcript, so the model can only select,
  never invent.
  """

  @max_link_lines 200

  @publishing_hosts ~w(medium.com substack.com dev.to hashnode.dev blogspot.com wordpress.com tumblr.com)
  @article_segments ~w(blog blogs post posts p article articles insights news stories author authors tag tags category pulse)
  @not_html ~w(.txt .xml .json .pdf .md .csv .rss)

  @doc """
  Why `url` is an article rather than a page a company publishes about
  itself, or `nil`. Decided from the URL alone, so it holds whatever the
  harvest model selected: the prompt asks it to skip articles and listicles,
  and it did not.
  """
  def article_reason(url) when is_binary(url) do
    uri = URI.parse(url)
    host = (uri.host || "") |> String.downcase() |> String.trim_leading("www.")
    path = String.downcase(uri.path || "")
    segments = String.split(path, "/", trim: true)
    slug = List.last(segments) || ""

    cond do
      Enum.any?(@publishing_hosts, &(host == &1 or String.ends_with?(host, "." <> &1))) ->
        :publishing_platform

      String.starts_with?(host, "blog.") ->
        :blog_host

      Path.extname(path) in @not_html ->
        :not_html

      Enum.any?(segments, &(&1 in @article_segments)) ->
        :article_path

      Regex.match?(~r"/(19|20)\d{2}[/-]\d{2}", path) ->
        :dated_path

      Regex.match?(~r/(^|-)(top|best)-\d+-|-of-(19|20)\d{2}$/, slug) ->
        :listicle

      # A title as a slug: "selling-my-bootstrapped-saas-business". Company
      # pages are a word or three: "leadership", "about-us/team".
      length(String.split(slug, "-")) >= 5 ->
        :long_slug

      true ->
        nil
    end
  end

  @doc """
  Harvest every transcript concurrently. Returns `{results, failures}`:
  results are engine/result-list pairs ready for merge, failures are
  `%{engine, query, reason}` maps for telemetry and the campaign ledger.
  """
  def from_transcripts(transcripts, opts) do
    harvested =
      Neuron.Pipeline.map(
        transcripts,
        fn transcript -> {transcript, harvest(transcript, opts)} end,
        max_concurrency: Keyword.get(opts, :harvest_concurrency, 4)
      )

    Enum.reduce(harvested, {[], []}, fn
      {transcript, {:ok, results}}, {found, failures} ->
        {[{transcript.engine, results} | found], failures}

      {transcript, {:error, reason}}, {found, failures} ->
        Neuron.Telemetry.emit(
          [:search, :harvest_failed],
          Neuron.Telemetry.trace_metadata(opts)
          |> Map.merge(%{engine: inspect(transcript.engine), reason: inspect(reason)})
        )

        {found,
         [
           %{
             engine: transcript.engine,
             query: transcript.query,
             kind: :harvest_failed,
             reason: inspect(reason)
           }
           | failures
         ]}
    end)
  end

  @doc "Read one transcript with the model and validate the selection."
  def harvest(transcript, opts) do
    # A page runner that returns no Markdown is read from its text. Reading
    # the key strictly raised inside the pipeline, the search stage retried,
    # and the campaign never left :search.
    content =
      case Map.get(transcript, :markdown, "") do
        "" -> transcript.text
        markdown -> markdown
      end

    assigns = %{
      engine: engine_label(transcript.engine),
      query: transcript.query,
      seller: Keyword.get(opts, :seller_domain, ""),
      url: transcript.url,
      content: content,
      links: format_links(transcript.links)
    }

    Neuron.Structured.generate(
      "search_harvest.eex",
      assigns,
      &validate(&1, transcript),
      opts
    )
  end

  defp validate(%{"results" => results}, transcript) when is_list(results) do
    allowed = MapSet.new([transcript.url | Enum.map(transcript.links, & &1.href)])

    valid? =
      Enum.all?(results, fn
        %{"title" => title, "url" => url} when is_binary(title) and is_binary(url) ->
          MapSet.member?(allowed, String.trim(url))

        _ ->
          false
      end)

    if valid? do
      normalized =
        Enum.map(results, fn result ->
          %{
            title: String.trim(result["title"]),
            url: String.trim(result["url"]),
            reason: String.trim(result["reason"] || "")
          }
        end)

      {:ok, Enum.uniq_by(normalized, & &1.url)}
    else
      {:error, :results_must_come_from_transcript}
    end
  end

  defp validate(_other, _transcript), do: {:error, :expected_results}

  defp format_links(links) do
    links
    |> Enum.take(@max_link_lines)
    |> Enum.map_join("\n", &"#{&1.label} — #{&1.href}")
  end

  defp engine_label(engine) when is_atom(engine), do: inspect(engine)
  defp engine_label(other), do: to_string(other)
end
