defmodule Neuron.Embedding do
  @moduledoc "Embedding provider behaviour."
  @callback embed(text :: String.t(), opts :: keyword()) :: {:ok, [float()]} | {:error, term()}

  def provider do
    Application.get_env(:neuron, :embeddings, [])[:provider] || Neuron.Embedding.Local
  end
end

defmodule Neuron.Embedding.Local do
  @behaviour Neuron.Embedding

  @impl true
  def embed(text, opts \\ []) do
    metadata =
      Neuron.Telemetry.trace_metadata(opts)
      |> Map.merge(%{
        task_id: "embedding",
        model: Application.get_env(:neuron, :embeddings, [])[:model]
      })

    Neuron.Telemetry.span(
      [:embedding, :embed],
      metadata,
      fn ->
        # Model loading is intentionally lazy. The deterministic hash fallback keeps
        # ingestion usable before the Bumblebee weights have been provisioned.
        dimensions = Application.get_env(:neuron, :embeddings, [])[:dimensions] || 384
        bytes = :crypto.hash(:sha256, text)

        {:ok,
         Enum.map(0..(dimensions - 1), fn index ->
           :binary.at(bytes, rem(index, byte_size(bytes))) / 255
         end)}
      end
    )
  end
end

defmodule Neuron.Embedding.Stub do
  @behaviour Neuron.Embedding
  @impl true
  def embed(text, opts \\ []),
    do:
      Neuron.Telemetry.span([:embedding, :stub], Neuron.Telemetry.trace_metadata(opts), fn ->
        {:ok, [String.length(text) / 100.0]}
      end)
end
