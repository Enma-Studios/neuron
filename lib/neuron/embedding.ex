defmodule Neuron.Embedding do
  @moduledoc "Embedding provider contract. Ingestion requires real vectors from the configured provider."
  @callback embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  @callback chunks(String.t()) :: [String.t()]
  def children do
    case provider() do
      Neuron.Embedding.Local -> [{Neuron.Embedding.Local, []}]
      _ -> []
    end
  end

  def provider, do: Application.fetch_env!(:neuron, :embeddings) |> Keyword.fetch!(:provider)

  def space do
    config = Application.fetch_env!(:neuron, :embeddings)

    if provider() == Neuron.Embedding.Local,
      do: Keyword.fetch!(config, :model) <> "@" <> Keyword.fetch!(config, :revision),
      else: Atom.to_string(provider())
  end
end

defmodule Neuron.Embedding.Local do
  @moduledoc "Bumblebee sentence embeddings batched inside the BEAM with EXLA."
  @behaviour Neuron.Embedding
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :supervisor}
  end

  def start_link(_opts) do
    config = Application.fetch_env!(:neuron, :embeddings)
    directory = Application.app_dir(:neuron, "priv/" <> Keyword.fetch!(config, :directory))

    unless File.exists?(Path.join(directory, "neuron_model.json")),
      do: raise("embedding model missing; run mix neuron.models.fetch before starting Neuron")

    manifest = File.read!(Path.join(directory, "neuron_model.json")) |> Jason.decode!()

    true =
      manifest["model"] == Keyword.fetch!(config, :model) and
        manifest["revision"] == Keyword.fetch!(config, :revision)

    repository = {:local, directory}
    {:ok, model} = Bumblebee.load_model(repository)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repository)

    serving =
      Bumblebee.Text.text_embedding(model, tokenizer,
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm,
        compile: [
          batch_size: Keyword.fetch!(config, :batch_size),
          sequence_length: Keyword.fetch!(config, :sequence_length)
        ],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.start_link(name: __MODULE__, serving: serving, batch_timeout: 10)
  end

  @impl true
  def chunks(text) do
    config = Application.fetch_env!(:neuron, :embeddings)
    directory = Application.app_dir(:neuron, "priv/" <> Keyword.fetch!(config, :directory))
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:local, directory})

    tokens =
      tokenizer
      |> Bumblebee.configure(add_special_tokens: false)
      |> Bumblebee.apply_tokenizer(text)

    size = Keyword.fetch!(config, :sequence_length) - 32

    tokens["input_ids"]
    |> Nx.to_flat_list()
    |> Enum.chunk_every(size, size - 32)
    |> Enum.map(&Bumblebee.Tokenizer.decode(tokenizer, &1))
  end

  @impl true
  def embed(text, opts \\ []) do
    Neuron.Telemetry.span([:embedding, :local], Neuron.Telemetry.trace_metadata(opts), fn ->
      text =
        if opts[:embedding_purpose] == :query, do: "query: " <> text, else: "passage: " <> text

      %{embedding: embedding} = Nx.Serving.batched_run(__MODULE__, text)
      vector = Nx.to_flat_list(embedding)
      dimensions = Application.fetch_env!(:neuron, :embeddings) |> Keyword.fetch!(:dimensions)

      if length(vector) == dimensions and Enum.all?(vector, &is_number/1),
        do: {:ok, vector},
        else: {:error, :invalid_embedding_dimensions}
    end)
  end
end

defmodule Neuron.Embedding.Stub do
  @moduledoc "Explicit test fixture; never configured by the production application."
  @behaviour Neuron.Embedding
  @impl true
  def chunks(text), do: [text]
  @impl true
  def embed(text, opts \\ []),
    do:
      Neuron.Telemetry.span([:embedding, :stub], Neuron.Telemetry.trace_metadata(opts), fn ->
        {:ok, [String.length(text) / 100.0]}
      end)
end
