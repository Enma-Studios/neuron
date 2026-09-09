defmodule Neuron.Telemetry do
  @moduledoc "Consistent, redacted traces for all Neuron side effects."
  @compile {:no_warn_undefined, :telemetry}

  def emit(event, metadata \\ %{}, measurements \\ %{}) do
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [
        [:neuron | List.wrap(event)],
        measurements,
        normalize(metadata)
      ])
    end

    write_log(event, measurements, metadata)

    :ok
  end

  def span(event, metadata, fun) when is_function(fun, 0) do
    started = System.monotonic_time()
    metadata = Map.put_new(metadata, :trace_id, trace_id())
    emit([:start | List.wrap(event)], metadata)

    try do
      result = fun.()
      emit([:stop | List.wrap(event)], metadata, %{duration: System.monotonic_time() - started})
      result
    rescue
      error ->
        emit(
          [:exception | List.wrap(event)],
          Map.put(metadata, :error, Exception.message(error)),
          %{duration: System.monotonic_time() - started}
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        emit(
          [:exception | List.wrap(event)],
          Map.merge(metadata, %{kind: kind, error: inspect(reason)}),
          %{duration: System.monotonic_time() - started}
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def trace_metadata(opts \\ [])

  def trace_metadata(opts) when is_list(opts) do
    opts
    |> Keyword.take([:trace_id, :run_id, :agent_id, :task_id, :operation_id, :attempt])
    |> Map.new()
    |> Map.put_new(:trace_id, trace_id())
  end

  def trace_metadata(opts) when is_map(opts) do
    opts
    |> Map.take([:trace_id, :run_id, :agent_id, :task_id, :operation_id, :attempt])
    |> Map.put_new(:trace_id, trace_id())
  end

  def summarize(value) do
    if Application.get_env(:neuron, :telemetry, [])[:capture_payloads] do
      value
    else
      %{
        sha256:
          :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower),
        bytes: byte_size(:erlang.term_to_binary(value))
      }
    end
  end

  def transcript(opts, event, payload) do
    path = Keyword.get(opts, :session_transcript) || System.get_env("NEURON_SESSION_TRANSCRIPT")

    if is_binary(path) and path != "" do
      line = "#{DateTime.utc_now()} #{event} #{inspect(payload, limit: :infinity)}\n"
      File.write!(path, line, [:append, :binary])
    end

    :ok
  end

  defp normalize(metadata), do: Map.new(metadata)

  defp write_log(event, measurements, metadata) do
    path =
      Application.get_env(:neuron, :telemetry, [])[:log_path] ||
        System.get_env("NEURON_TELEMETRY_LOG")

    if is_binary(path) and path != "" do
      line =
        "#{DateTime.utc_now()} event=#{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata, limit: :infinity)}\n"

      try do
        File.write(path, line, [:append, :binary])
      rescue
        _ -> :ok
      end
    end
  end

  defp trace_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
