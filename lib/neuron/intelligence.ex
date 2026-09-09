defmodule Neuron.Intelligence do
  @moduledoc "End-to-end web exploration, evidence capture, and campaign-fit scoring."

  def explore(url, fit_profile, opts \\ []) when is_binary(url) and is_map(fit_profile) do
    run_id = Keyword.get(opts, :run_id, "adhoc-#{System.unique_integer([:positive])}")
    opts = Keyword.put(opts, :run_id, run_id)

    Neuron.Telemetry.span(
      [:intelligence, :explore],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:task_id, "intelligence:explore"),
      fn ->
        with {:ok, page} <- Neuron.Browser.fetch(url, opts),
             {:ok, snapshot} <- snapshot(page, url, opts),
             {:ok, embedding} <- embed(snapshot.markdown, opts),
             {:ok, decision} <- Neuron.Lead.evaluate(candidate(page, snapshot), fit_profile, opts),
             :ok <- persist_snapshot(run_id, snapshot, embedding, decision, opts) do
          {:ok,
           %{
             run_id: run_id,
             url: url,
             provider: page[:provider],
             snapshot: snapshot,
             embedding: embedding,
             decision: decision
           }}
        end
      end
    )
  end

  defp persist_snapshot(run_id, snapshot, embedding, decision, opts) do
    if Keyword.get(opts, :persist, true) do
      Neuron.Graph.upsert(
        %{
          "uid" => "_:snapshot-#{run_id}",
          "dgraph.type" => ["Snapshot", "Entity"],
          "url" => snapshot[:url],
          "markdown" => snapshot.markdown,
          Neuron.Embedding.field() => embedding,
          "reason" => Enum.join(decision.reasons, " "),
          "fit_score" => decision.score
        },
        run_id: run_id,
        task_id: "intelligence:graph_upsert"
      )
    else
      :ok
    end
  end

  def explore_many(urls, fit_profile, opts \\ []) do
    max_concurrency =
      Keyword.get(
        opts,
        :max_concurrency,
        Application.get_env(:neuron, :limits, [])[:max_runs] || 8
      )

    urls
    |> Task.async_stream(&explore(&1, fit_profile, opts),
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: Keyword.get(opts, :timeout, 120_000),
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exploration_exit, reason}}
    end)
  end

  def discover(query, fit_profile, opts \\ []) when is_binary(query) do
    with {:ok, results} <- Neuron.Search.web(query, opts) do
      urls = Enum.map(results, & &1.url)
      explore_many(urls, fit_profile, opts)
    end
  end

  defp snapshot(page, url, opts) do
    html = page[:html] || page["html"]

    if is_binary(html) do
      Neuron.Snapshot.from_html(
        html,
        Map.merge(
          %{url: page[:url] || page["url"] || url, title: page[:title] || page["title"]},
          Neuron.Telemetry.trace_metadata(opts)
        )
      )
    else
      {:error, :browser_returned_no_html}
    end
  end

  defp embed(markdown, opts) do
    provider = Keyword.get(opts, :embedding_provider, Neuron.Embedding.provider())
    provider.embed(markdown, opts)
  end

  defp candidate(page, snapshot) do
    %{
      url: snapshot[:url] || page[:url],
      title: snapshot[:title] || page[:title],
      excerpt: snapshot.markdown,
      body: snapshot.markdown,
      geography: page[:geography] || page["geography"]
    }
  end
end

defmodule Neuron.Coordinator.Intelligence do
  @moduledoc "Coordinator profile that runs the web intelligence pipeline."
  @behaviour Neuron.Coordinator

  @impl true
  def plan(input, _context) when is_map(input) do
    urls = input[:urls] || input["urls"] || List.wrap(input[:url] || input["url"])
    fit_profile = input[:fit_profile] || input["fit_profile"] || %{}

    if urls == [] do
      {:error, :no_urls}
    else
      {:ok, %{urls: urls, fit_profile: fit_profile}}
    end
  end

  @impl true
  def run(%{urls: urls, fit_profile: fit_profile}, context) do
    options = Keyword.put(context[:options] || [], :run_id, context[:run_id])

    Neuron.Intelligence.explore_many(urls, fit_profile, options)
    |> then(&{:ok, &1})
  end
end
