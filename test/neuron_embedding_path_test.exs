defmodule Neuron.EmbeddingPathTest do
  use ExUnit.Case, async: false

  # A host application's working directory is not Neuron's. Every case here
  # runs from inside one, because the standalone case is the only one that
  # ever worked and it hid the bug.

  setup do
    original = Application.fetch_env!(:neuron, :embeddings)
    cwd = File.cwd!()
    unique = System.unique_integer([:positive])

    host = Path.join(System.tmp_dir!(), "neuron-host-app-#{unique}")
    File.mkdir_p!(Path.join(host, "priv"))

    # A model directory of its own, so a real fetched model on the developer's
    # machine cannot satisfy any assertion here.
    Application.put_env(
      :neuron,
      :embeddings,
      Keyword.merge(original,
        directory: "models/host-test-#{unique}",
        model: "acme/embedder",
        revision: "abc123"
      )
    )

    resolved = Neuron.Embedding.directory()

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(resolved)
      File.rm_rf!(host)
      Application.put_env(:neuron, :embeddings, original)
    end)

    {:ok, host: host, resolved: resolved}
  end

  test "the fetch target and the loader resolve one directory from a host app", %{
    host: host,
    resolved: resolved
  } do
    File.cd!(host)

    assert Neuron.Embedding.directory() == resolved
    refute String.starts_with?(Neuron.Embedding.directory(), host)
    assert String.starts_with?(Neuron.Embedding.directory(), Application.app_dir(:neuron))
  end

  test "a model written by the fetch task loads inside a host app", %{host: host} do
    File.cd!(host)

    # What mix neuron.models.fetch does, resolved the way the task resolves it.
    directory = Neuron.Embedding.directory()
    File.mkdir_p!(directory)

    File.write!(
      Neuron.Embedding.manifest_path(),
      Jason.encode!(%{model: "acme/embedder", revision: "abc123"})
    )

    # What the application does at startup, from the same host working directory.
    assert Neuron.Embedding.load!() == directory
  end

  test "a model in the host's own priv is reported as misplaced, not missing", %{host: host} do
    File.cd!(host)
    # macOS resolves the temporary directory through a symlink, so the host
    # path is read back rather than assumed.
    host = File.cwd!()

    # Where the fetch task used to write when Neuron was a dependency.
    legacy = Path.expand(Application.fetch_env!(:neuron, :embeddings)[:directory], "priv")
    File.mkdir_p!(legacy)

    File.write!(
      Path.join(legacy, "neuron_model.json"),
      Jason.encode!(%{model: "acme/embedder", revision: "abc123"})
    )

    assert {:error, {:misplaced, found, expected}} = Neuron.Embedding.manifest()
    assert String.starts_with?(found, host)
    assert expected == Neuron.Embedding.directory()

    assert_raise RuntimeError, ~r/but Neuron reads/, fn -> Neuron.Embedding.load!() end
  end

  test "a model that was never fetched is reported as missing", %{host: host} do
    File.cd!(host)

    assert Neuron.Embedding.manifest() == {:error, :missing}

    assert_raise RuntimeError, ~r/missing at .*run mix neuron.models.fetch/s, fn ->
      Neuron.Embedding.load!()
    end
  end

  test "a fetched model that does not match configuration is reported as neither", %{host: host} do
    File.cd!(host)
    File.mkdir_p!(Neuron.Embedding.directory())

    File.write!(
      Neuron.Embedding.manifest_path(),
      Jason.encode!(%{model: "acme/embedder", revision: "stale99"})
    )

    assert_raise RuntimeError, ~r/is acme\/embedder@stale99, but/, fn ->
      Neuron.Embedding.load!()
    end
  end
end
