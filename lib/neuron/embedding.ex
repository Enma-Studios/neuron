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

  @manifest "neuron_model.json"

  @doc """
  The one directory the pinned embedding model lives in.

  `mix neuron.models.fetch` used to resolve this against the current working
  directory while the loader resolved it against Neuron's own application
  directory. Those agree only when Neuron is the project being run. As a
  dependency the fetch wrote into the host's `priv` and the loader then read
  Neuron's, so the documented setup always ended in `embedding model
  missing`, naming the command that had just succeeded. Both resolve it
  here now, so they cannot drift apart again.
  """
  def directory do
    _ = Application.load(:neuron)
    Application.app_dir(:neuron, "priv/" <> Keyword.fetch!(config(), :directory))
  end

  @doc "Path of the manifest the fetch task writes and the loader verifies."
  def manifest_path, do: Path.join(directory(), @manifest)

  @doc """
  The fetched model's manifest, or why it cannot be used.

  A model in the wrong place is reported separately from one that was never
  fetched: the first needs the fetch re-running against this application,
  the second needs it running at all.
  """
  def manifest do
    cond do
      File.exists?(manifest_path()) ->
        {:ok, manifest_path() |> File.read!() |> Jason.decode!()}

      File.exists?(legacy_manifest_path()) ->
        {:error, {:misplaced, legacy_manifest_path(), directory()}}

      true ->
        {:error, :missing}
    end
  end

  @doc """
  Verify the fetched model against configuration and return its directory.
  Raises with the distinction between missing, misplaced, and mismatched.
  """
  def load! do
    config = config()

    case manifest() do
      {:ok, %{"model" => model, "revision" => revision}} ->
        expected = {Keyword.fetch!(config, :model), Keyword.fetch!(config, :revision)}

        if {model, revision} != expected do
          raise "embedding model at #{directory()} is #{model}@#{revision}, but " <>
                  "#{elem(expected, 0)}@#{elem(expected, 1)} is configured; re-run mix neuron.models.fetch"
        end

        directory()

      {:error, {:misplaced, found, expected}} ->
        raise "embedding model found at #{found} but Neuron reads #{expected}; " <>
                "re-run mix neuron.models.fetch so it writes where the loader looks"

      {:error, :missing} ->
        raise "embedding model missing at #{directory()}; " <>
                "run mix neuron.models.fetch before starting Neuron"

      {:ok, _other} ->
        raise "embedding manifest at #{manifest_path()} is unreadable; re-run mix neuron.models.fetch"
    end
  end

  # Where the fetch task used to write: relative to the working directory,
  # which is the host's priv whenever Neuron is a dependency.
  defp legacy_manifest_path,
    do: Path.join(Path.expand(Keyword.fetch!(config(), :directory), "priv"), @manifest)

  defp config, do: Application.fetch_env!(:neuron, :embeddings)

  def space do
    config = Application.fetch_env!(:neuron, :embeddings)

    if provider() == Neuron.Embedding.Local,
      do: Keyword.fetch!(config, :model) <> "@" <> Keyword.fetch!(config, :revision),
      else: Atom.to_string(provider())
  end

  @doc "Dgraph predicate reserved for the supported multilingual E5 vector shape."
  def field, do: "embedding_e5_384"
end

defmodule Neuron.Embedding.Local do
  @moduledoc "Bumblebee sentence embeddings batched inside the BEAM with EXLA."
  @behaviour Neuron.Embedding
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :supervisor}
  end

  def start_link(_opts) do
    config = Application.fetch_env!(:neuron, :embeddings)
    repository = {:local, Neuron.Embedding.load!()}
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
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:local, Neuron.Embedding.directory()})

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
