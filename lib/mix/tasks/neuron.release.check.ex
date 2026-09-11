defmodule Mix.Tasks.Neuron.Release.Check do
  use Mix.Task
  @shortdoc "Fail unless the mix.exs version matches the tag being cut"
  @moduledoc """
  Run `mix neuron.release.check v0.2.5` before tagging a release.

  A tag is a fixed point once pushed, so a tag cut at a commit whose
  `mix.exs` says something else cannot be corrected afterwards without
  moving it, which `docs/operations.md` forbids. The only place to catch
  that is before the tag exists. `v0.2.4` was cut at a commit declaring
  `0.2.3` and had to stay that way.

  With no argument it checks whatever tags already point at `HEAD`, and
  passes quietly when there are none, so it is safe to run anywhere.
  """
  def run(args) do
    Mix.Task.run("loadpaths")

    case check(args) do
      :ok ->
        Mix.shell().info("version #{version()} matches the tag being cut")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc """
  `:ok`, or `{:error, message}` when the declared version and the tag
  disagree. With no tag, every tag already on `HEAD` must agree; a commit
  with no tags has nothing to contradict and passes.
  """
  def check(args \\ [])

  def check([tag | _]), do: compare(tag, version())

  def check([]) do
    case tags_on_head() do
      [] -> :ok
      tags -> Enum.find_value(tags, :ok, &error(compare(&1, version())))
    end
  end

  @doc "The version `mix.exs` declares."
  def version, do: Mix.Project.config()[:version]

  @doc "Compare one tag against one version, both as given."
  def compare(tag, version) do
    case normalize(tag) do
      {:ok, ^version} ->
        :ok

      {:ok, tagged} ->
        {:error,
         "tag #{tag} declares #{tagged} but mix.exs declares #{version}; " <>
           "bump mix.exs and tag that commit, never move the tag afterwards"}

      :error ->
        {:error, "#{inspect(tag)} is not a version tag; expected something like v1.2.3"}
    end
  end

  defp normalize("v" <> rest), do: normalize(rest)

  defp normalize(tag) when is_binary(tag) do
    if Regex.match?(~r/^\d+\.\d+\.\d+(-[\w.]+)?$/, tag), do: {:ok, tag}, else: :error
  end

  defp normalize(_), do: :error

  defp error(:ok), do: nil
  defp error(other), do: other

  # A checkout without git, or without a repository, has nothing to say
  # about tags and must not fail the build for it.
  defp tags_on_head do
    case System.cmd("git", ["tag", "--points-at", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  rescue
    _ -> []
  end
end
