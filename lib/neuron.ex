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

  @doc "Start a coordinator and wait for its terminal result, including lead data."
  def run(profile \\ Neuron.Coordinator.default(), input, opts \\ []) do
    with {:ok, id} <- start_run(profile, input, opts),
         {:ok, response} <- await_run(id, Keyword.get(opts, :timeout, 120_000)) do
      {:ok, Map.put(response, :id, id)}
    end
  end

  @doc "Wait for a durable run and return its result instead of only its process id."
  def await_run(id, timeout \\ 120_000) when is_binary(id) and is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(id, deadline)
  end

  def get_run(id), do: Neuron.Run.call(id, :get)

  def list_runs do
    case Neuron.Storage.list_runs() do
      {:atomic, runs} ->
        Enum.map(runs, fn {:neuron_run, id, profile, _input, status, inserted, updated, result,
                           error} ->
          %{
            id: id,
            profile: profile,
            status: status,
            inserted_at: inserted,
            updated_at: updated,
            result: result,
            error: error
          }
        end)

      error ->
        error
    end
  end

  def events(id) do
    case Neuron.Storage.events(id) do
      {:atomic, events} -> events
      error -> error
    end
  end

  def cancel_run(id), do: Neuron.Run.call(id, :cancel)
  def provide_run(id, input) when is_map(input), do: Neuron.Run.call(id, {:provide, input})

  defp await_loop(id, deadline) do
    response = persisted_or_live_run(id)

    cond do
      is_map(response) and response.status == :complete ->
        {:ok, response}

      is_map(response) and response.status == :needs_input ->
        {:needs_input, response}

      is_map(response) and response.status in [:failed, :cancelled] ->
        {:error, response}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(25)
        await_loop(id, deadline)
    end
  end

  defp persisted_or_live_run(id) do
    live =
      try do
        get_run(id)
      catch
        :exit, _ -> nil
      end

    live ||
      case Neuron.Storage.get_run(id) do
        {:ok, {:neuron_run, ^id, profile, input, status, inserted, updated, result, error}} ->
          %{
            id: id,
            profile: profile,
            input: input,
            status: status,
            inserted_at: inserted,
            updated_at: updated,
            result: result,
            error: error
          }

        _ ->
          nil
      end
  end

  def spawn_agent(run_id, role, worker \\ Neuron.Agent.Echo, input, opts \\ []) do
    id = Keyword.get(opts, :id, random_id())
    parent_id = Keyword.get(opts, :parent_id)

    case Neuron.AgentSupervisor.start_agent(id, run_id, parent_id, role, worker, input, opts) do
      {:ok, _pid} -> {:ok, id}
      error -> error
    end
  end

  def get_agent(id), do: Neuron.Agent.call(id, :get)
  def cancel_agent(id), do: Neuron.Agent.call(id, :cancel)

  def resume_run(id) do
    case Neuron.Storage.get_run(id) do
      {:ok, {:neuron_run, ^id, profile, input, status, _inserted, _updated, result, error}}
      when status in [:queued, :planning, :executing] ->
        case Neuron.RunSupervisor.start_run(id, profile, input,
               resumed: true,
               result: result,
               error: error
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> {:error, :already_running}
          error -> error
        end

      {:ok, {:neuron_run, ^id, _profile, _input, status, _, _, _, _}} ->
        {:error, {:not_resumable, status}}

      :not_found ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp normalize_profile(profile) when is_atom(profile), do: profile
  defp normalize_profile(profile) when is_map(profile), do: Map.fetch!(profile, :module)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
