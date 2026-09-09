defmodule Neuron.Lead do
  @moduledoc "Transparent campaign-fit scoring with durable evidence and reasons."

  @type decision :: %{
          candidate: map(),
          fit_profile: map(),
          score: float(),
          selected: boolean(),
          reasons: [String.t()],
          evidence: [map()]
        }

  @doc "Score a candidate against a fit profile and explain every criterion."
  @spec evaluate(map(), map(), keyword()) :: {:ok, decision()}
  def evaluate(candidate, fit_profile, opts \\ [])
      when is_map(candidate) and is_map(fit_profile) do
    required =
      List.wrap(Map.get(fit_profile, :requirements, Map.get(fit_profile, "requirements", [])))

    preferred =
      List.wrap(
        Map.get(
          fit_profile,
          :preferred_geographies,
          Map.get(fit_profile, "preferred_geographies", [])
        )
      )

    candidate_text = text(candidate)
    threshold = Map.get(fit_profile, :threshold, Map.get(fit_profile, "threshold", 0.6))

    requirement_results = Enum.map(required, &requirement_result(&1, candidate_text, candidate))
    geography_result = geography_result(preferred, candidate)
    matched = Enum.count(requirement_results, & &1.matched)
    requirement_score = if required == [], do: 1.0, else: matched / length(required)
    score = Float.round(requirement_score * 0.8 + geography_result.score * 0.2, 4)
    selected = score >= threshold

    reasons =
      requirement_results
      |> Enum.map(& &1.reason)
      |> Kernel.++([geography_result.reason, selection_reason(selected, score, threshold)])

    evidence =
      requirement_results
      |> Enum.filter(& &1.matched)
      |> Enum.map(fn result -> %{criterion: result.criterion, excerpt: result.excerpt} end)

    decision = %{
      candidate: candidate,
      fit_profile: fit_profile,
      score: score,
      selected: selected,
      reasons: reasons,
      evidence: evidence
    }

    metadata = Neuron.Telemetry.trace_metadata(opts) |> Map.put(:task_id, "lead:fit_decision")

    Neuron.Telemetry.emit(
      [:lead, :decision],
      Map.merge(metadata, %{
        score: score,
        selected: selected,
        reasons: reasons,
        evidence: Neuron.Telemetry.summarize(evidence)
      })
    )

    if run_id = Keyword.get(opts, :run_id) do
      Neuron.Storage.next_event(run_id, :lead_decision, decision, metadata)
    end

    {:ok, decision}
  end

  defp requirement_result(requirement, candidate_text, candidate) do
    description =
      Map.get(
        requirement,
        :description,
        Map.get(requirement, "description", requirement |> inspect())
      )

    keywords =
      description
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) > 2))

    matched = keywords == [] or Enum.any?(keywords, &String.contains?(candidate_text, &1))
    criterion = Map.get(requirement, :category, Map.get(requirement, "category", "requirement"))
    excerpt = Map.get(candidate, :excerpt, Map.get(candidate, "excerpt", candidate_text))

    reason =
      if matched do
        "Matched #{criterion}: #{description}"
      else
        "No evidence matched #{criterion}: #{description}"
      end

    %{matched: matched, criterion: criterion, reason: reason, excerpt: excerpt}
  end

  defp geography_result([], _candidate),
    do: %{score: 1.0, reason: "No geography restriction was supplied"}

  defp geography_result(preferred, candidate) do
    candidate_geo =
      candidate
      |> Map.get(:geography, Map.get(candidate, "geography", ""))
      |> to_string()
      |> String.downcase()

    matched = Enum.any?(preferred, &(String.downcase(to_string(&1)) in [candidate_geo, "global"]))

    %{
      score: if(matched, do: 1.0, else: 0.0),
      reason:
        if(matched,
          do: "Geography #{candidate_geo} is preferred",
          else: "Geography #{candidate_geo} is outside the preferred set"
        )
    }
  end

  defp selection_reason(true, score, threshold),
    do: "Selected with score #{score} at or above threshold #{threshold}"

  defp selection_reason(false, score, threshold),
    do: "Not selected with score #{score} below threshold #{threshold}"

  defp text(candidate) do
    candidate
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end
end
