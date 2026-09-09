defmodule Neuron do
  @moduledoc "Public API for durable Neuron runs."

  def start_run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    id = Keyword.get(opts, :id, random_id())
    profile = normalize_profile(profile)

    case Neuron.RunSupervisor.start_run(id, profile, input, opts) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      other -> other
    end
  end

  def get_run(id), do: Neuron.Run.call(id, :get)

  def list_runs do
    case Neuron.Storage.list_runs() do
      {:atomic, runs} -> Enum.map(runs, fn {:neuron_run, id, profile, _input, status, inserted, updated, result, error} -> %{id: id, profile: profile, status: status, inserted_at: inserted, updated_at: updated, result: result, error: error} end)
      error -> error
    end
  end

  def events(id) do
    case Neuron.Storage.events(id) do
      {:atomic, events} -> events
      error -> error
    end
  end

  def cancel_run(id), do: Neuron.Run.call(id, :cancel)

  def resume_run(id) do
    case Neuron.Storage.get_run(id) do
      {:ok, {:neuron_run, ^id, profile, input, status, _inserted, _updated, result, error}} when status in [:queued, :planning, :executing] ->
        case Neuron.RunSupervisor.start_run(id, profile, input, resumed: true, result: result, error: error) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> {:error, :already_running}
          error -> error
        end

      {:ok, {:neuron_run, ^id, _profile, _input, status, _, _, _, _}} -> {:error, {:not_resumable, status}}
      :not_found -> {:error, :not_found}
      error -> error
    end
  end

  defp normalize_profile(profile) when is_atom(profile), do: profile
  defp normalize_profile(profile) when is_map(profile), do: Map.fetch!(profile, :module)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
