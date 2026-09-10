defmodule Neuron.Usage.Entry do
  use Ecto.Schema

  schema "neuron_usage" do
    field(:run_id, :string)
    field(:parent_run_id, :string)
    field(:stage, :string)
    field(:kind, :string)
    field(:label, :string)
    field(:prompt_tokens, :integer, default: 0)
    field(:cached_tokens, :integer, default: 0)
    field(:completion_tokens, :integer, default: 0)
    field(:seconds, :float, default: 0.0)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Neuron.Usage do
  @moduledoc """
  What a run spent, recorded where it was spent.

  Every model call records its prompt and completion tokens against the
  model that served it, and every browser session records its seconds
  against the provider that ran it, both tagged with the run and the stage
  they happened in. A stage is one Oban job in its own process, so this is
  kept in SQL rather than in memory: nothing else survives from the stage
  that made the call to the caller that asks what the run cost.

  Rows carry `parent_run_id` as well, so a campaign's total includes the
  ingestion children it dispatched rather than only the parent's own calls.
  """
  import Ecto.Query
  alias Neuron.Usage.Entry

  @empty %{
    model_calls: 0,
    prompt_tokens: 0,
    cached_tokens: 0,
    completion_tokens: 0,
    browser_sessions: 0,
    browser_seconds: 0.0,
    graph_conflicts: 0
  }

  @doc "Record one model call's token usage against its run and stage."
  def record_model(response, opts) do
    usage = (is_map(response) && response["usage"]) || %{}

    record(
      %{
        kind: "model",
        label: opts[:model] || Application.get_env(:neuron, :model, [])[:model],
        prompt_tokens: integer(usage["prompt_tokens"]),
        # Z.ai caches request prefixes implicitly and reports the reused
        # span here. This is the only honest evidence that a cached prefix
        # was hit; repeated text alone proves nothing.
        cached_tokens: integer(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
        completion_tokens: integer(usage["completion_tokens"])
      },
      opts
    )
  end

  @doc """
  Record one graph write that exhausted its conflict retries.

  Evidence was gathered and then lost, so the run must say so rather than
  look clean. Counted only when the retries ran out: a conflict the retry
  absorbed cost time, not data.
  """
  def record_conflict(opts), do: record(%{kind: "graph_conflict", label: "dgraph"}, opts)

  @doc "Record one browser session's wall time against its run and stage."
  def record_browser(seconds, opts) do
    record(
      %{kind: "browser", label: to_string(opts[:provider] || :browser_use), seconds: seconds},
      opts
    )
  end

  @doc """
  Record one usage row. Accounting must never be the reason a run fails, so
  a write that cannot land is traced and dropped rather than raised.
  """
  def record(attrs, opts) do
    run_id = opts[:run_id]

    if is_binary(run_id) do
      Neuron.Persistence.repo().insert!(
        struct(
          Entry,
          Map.merge(
            %{
              run_id: run_id,
              parent_run_id: opts[:parent_run_id],
              stage: opts[:stage] && to_string(opts[:stage]),
              inserted_at: DateTime.utc_now()
            },
            attrs
          )
        )
      )

      :ok
    else
      :ok
    end
  rescue
    error ->
      Neuron.Telemetry.emit([:usage, :dropped], %{error: Exception.message(error)})
      :ok
  catch
    kind, reason ->
      Neuron.Telemetry.emit([:usage, :dropped], %{kind: kind, error: inspect(reason)})
      :ok
  end

  @doc """
  What `run_id` and the children it dispatched spent, per model, per
  provider, per stage, and in total, including graph writes that lost their
  entity to a concurrent writer and ran out of retries.
  """
  def snapshot(run_id) do
    entries =
      Neuron.Persistence.repo().all(
        from(e in Entry, where: e.run_id == ^run_id or e.parent_run_id == ^run_id)
      )

    %{
      models: by_label(entries, "model"),
      browser: by_label(entries, "browser"),
      by_stage:
        Map.new(Enum.group_by(entries, & &1.stage), fn {stage, rows} ->
          {stage || "unknown", totals(rows)}
        end),
      total: totals(entries)
    }
  end

  @doc """
  Which subsystem a failed run's error came from: `:storage`, `:model`,
  `:browser`, `:budget`, `:search`, or `:unknown`.

  A host renders a cause from this, so an error shape nobody has seen
  before must classify as `:unknown` rather than crash the caller or be
  guessed into the nearest familiar bucket.
  """
  def error_class(nil), do: nil

  def error_class(error) do
    text = inspect(error)

    cond do
      match_any?(text, ["Dlex", "dgraph", "Dgraph", "Ecto.", "DBConnection", ":storage"]) ->
        :storage

      match_any?(text, [
        "zai",
        "ZAI",
        "invalid_model_output",
        "invalid_model_shape",
        "model_provider"
      ]) ->
        :model

      match_any?(text, ["browser_use", "fleet", "page_not_ready", "page_error", "Pinocchio"]) ->
        :browser

      match_any?(text, ["budget", "cost_cap", "spend"]) ->
        :budget

      match_any?(text, ["search_unavailable", "no_valid_searches", "expected_searches"]) ->
        :search

      true ->
        :unknown
    end
  end

  defp match_any?(text, markers), do: Enum.any?(markers, &String.contains?(text, &1))

  defp by_label(entries, kind) do
    entries
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.group_by(& &1.label)
    |> Enum.map(fn {label, rows} -> Map.put(totals(rows), :label, label) end)
    |> Enum.sort_by(& &1.label)
  end

  defp totals(entries) do
    Enum.reduce(entries, @empty, fn entry, acc ->
      case entry.kind do
        "model" ->
          %{
            acc
            | model_calls: acc.model_calls + 1,
              prompt_tokens: acc.prompt_tokens + (entry.prompt_tokens || 0),
              cached_tokens: acc.cached_tokens + (entry.cached_tokens || 0),
              completion_tokens: acc.completion_tokens + (entry.completion_tokens || 0)
          }

        "browser" ->
          %{
            acc
            | browser_sessions: acc.browser_sessions + 1,
              browser_seconds: acc.browser_seconds + (entry.seconds || 0.0)
          }

        "graph_conflict" ->
          %{acc | graph_conflicts: acc.graph_conflicts + 1}

        _ ->
          acc
      end
    end)
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
end
