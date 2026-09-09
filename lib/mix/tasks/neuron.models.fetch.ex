defmodule Mix.Tasks.Neuron.Models.Fetch do
  use Mix.Task
  @shortdoc "Download the pinned embedding model into priv/models"
  @moduledoc "Run `mix neuron.models.fetch` before application startup or building a release. Model files are ignored by Git."
  @files ~w(config.json model.safetensors tokenizer.json tokenizer_config.json special_tokens_map.json sentencepiece.bpe.model README.md)
  def run([]) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:req)
    config = Application.fetch_env!(:neuron, :embeddings)
    model = Keyword.fetch!(config, :model)
    revision = Keyword.fetch!(config, :revision)
    directory = Path.expand(Keyword.fetch!(config, :directory), "priv")
    File.mkdir_p!(directory)

    for file <- @files do
      path = Path.join(directory, file)
      Mix.shell().info("Fetching #{model}@#{revision}/#{file}")

      response =
        Req.get!("https://huggingface.co/#{model}/resolve/#{revision}/#{file}",
          into: File.stream!(path <> ".part"),
          receive_timeout: 120_000
        )

      if response.status != 200,
        do: Mix.raise("model download failed: #{file}, HTTP #{response.status}")

      File.rename!(path <> ".part", path)
    end

    File.write!(
      Path.join(directory, "neuron_model.json"),
      Jason.encode!(%{model: model, revision: revision})
    )

    Mix.shell().info("Embedding model ready at #{directory}")
  end
end
