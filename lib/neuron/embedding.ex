defmodule Neuron.Embedding do
  @moduledoc "Embedding provider contract. Ingestion requires real vectors from the configured provider."
  @callback embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def provider, do: Application.fetch_env!(:neuron, :embeddings) |> Keyword.fetch!(:provider)
end

defmodule Neuron.Embedding.HTTP do
  @moduledoc "Calls an explicitly configured OpenAI-compatible embeddings endpoint."
  @behaviour Neuron.Embedding
  @impl true
  def embed(text, opts \\ []) do
    config = Application.fetch_env!(:neuron, :embeddings)
    endpoint = Keyword.fetch!(config, :endpoint)
    model = Keyword.fetch!(config, :model)
    dimensions = Keyword.fetch!(config, :dimensions)

    headers =
      case config[:api_key] do
        nil -> []
        key -> [{"authorization", "Bearer " <> key}]
      end

    Neuron.Telemetry.span([:embedding, :embed], Neuron.Telemetry.trace_metadata(opts), fn ->
      with {:ok, response} <-
             Req.post(endpoint,
               headers: headers,
               json: %{model: model, input: text},
               retry: false
             ),
           %{status: 200, body: %{"data" => [%{"embedding" => vector}]}} <- response,
           true <-
             is_list(vector) and length(vector) == dimensions and Enum.all?(vector, &is_number/1) do
        {:ok, Enum.map(vector, &(&1 * 1.0))}
      else
        false -> {:error, :invalid_embedding_dimensions}
        {:error, reason} -> {:error, reason}
        response -> {:error, {:embedding_response, response}}
      end
    end)
  end
end

defmodule Neuron.Embedding.Stub do
  @moduledoc "Explicit test fixture; never configured by the production application."
  @behaviour Neuron.Embedding
  @impl true
  def embed(text, opts \\ []),
    do:
      Neuron.Telemetry.span([:embedding, :stub], Neuron.Telemetry.trace_metadata(opts), fn ->
        {:ok, [String.length(text) / 100.0]}
      end)
end
