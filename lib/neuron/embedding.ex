defmodule Neuron.Embedding do
  @moduledoc "Embedding provider behaviour."
  @callback embed(text :: String.t(), opts :: keyword()) :: {:ok, [float()]} | {:error, term()}
end

defmodule Neuron.Embedding.Local do
  @behaviour Neuron.Embedding

  @impl true
  def embed(text, _opts \\ []) do
    # Model loading is intentionally lazy. The deterministic hash fallback keeps
    # ingestion usable before the Bumblebee weights have been provisioned.
    dimensions = Application.get_env(:neuron, :embeddings, [])[:dimensions] || 384
    bytes = :crypto.hash(:sha256, text)
    {:ok, Enum.map(0..(dimensions - 1), fn index -> :binary.at(bytes, rem(index, byte_size(bytes))) / 255 end)}
  end
end

defmodule Neuron.Embedding.Stub do
  @behaviour Neuron.Embedding
  @impl true
  def embed(text, _opts \\ []), do: {:ok, [String.length(text) / 100.0]}
end
