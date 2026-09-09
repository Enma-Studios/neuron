defmodule Neuron.Model do
  @moduledoc "Model provider behaviour."
  @callback complete(messages :: [map()], opts :: keyword()) :: {:ok, map()} | {:error, term()}
end

defmodule Neuron.Model.ZAI do
  @behaviour Neuron.Model

  @impl true
  def complete(messages, opts \\ []) do
    metadata = Neuron.Telemetry.trace_metadata(opts) |> Map.put(:task_id, "model:complete")
    Neuron.Telemetry.span([:model, :complete], metadata, fn -> do_complete(messages, opts) end)
  end

  defp do_complete(messages, opts) do
    config = Application.get_env(:neuron, :model, []) |> Keyword.merge(opts)
    api_key = config[:api_key] || System.get_env("ZAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_zai_api_key}
    else
      body = %{
        model: config[:model] || "glm-5.3-flash",
        messages: messages,
        stream: false,
        temperature: config[:temperature] || 1,
        reasoning_effort: config[:reasoning_effort] || "max"
      }

      url = String.trim_trailing(config[:base_url] || "https://api.z.ai/api/paas/v4", "/") <> "/chat/completions"
      headers = [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}]

      Neuron.Telemetry.emit([:model, :request], %{model: body.model, prompt: Neuron.Telemetry.summarize(messages)})

      case apply(Req, :post, [url, [headers: headers, json: body, receive_timeout: config[:timeout] || 120_000]]) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          message = get_in(response, ["choices", Access.at(0), "message"]) || %{}
          Neuron.Telemetry.emit([:model, :decision], %{model: body.model, reasoning: Neuron.Telemetry.summarize(message["reasoning_content"]), tool_calls: message["tool_calls"] || []})
          {:ok, response}
        {:ok, %{status: status, body: response}} -> {:error, {:zai_http, status, response}}
        {:error, reason} -> {:error, {:zai_transport, reason}}
      end
    end
  end
end

defmodule Neuron.Model.Stub do
  @behaviour Neuron.Model
  @impl true
  def complete(messages, opts) do
    Neuron.Telemetry.emit([:model, :stub_decision], Map.merge(Neuron.Telemetry.trace_metadata(opts), %{prompt: Neuron.Telemetry.summarize(messages)}))
    {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => inspect(messages)}}]}}
  end
end
