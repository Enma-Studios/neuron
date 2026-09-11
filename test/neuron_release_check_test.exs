defmodule Neuron.ReleaseCheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Neuron.Release.Check

  test "a tag that matches the declared version passes" do
    assert Check.check(["v" <> Check.version()]) == :ok
    assert Check.check([Check.version()]) == :ok
  end

  test "a tag that does not match the declared version fails, and says which is which" do
    assert {:error, message} = Check.check(["v9.9.9"])
    assert message =~ "tag v9.9.9 declares 9.9.9"
    assert message =~ "mix.exs declares #{Check.version()}"
    assert message =~ "never move the tag"
  end

  test "the v0.2.4 mistake is exactly what this rejects" do
    # Cut at a commit whose mix.exs declared 0.2.3. A tag cannot be
    # corrected after it is published, so this has to fail before it exists.
    assert {:error, _} = Check.compare("v0.2.4", "0.2.3")
    assert Check.compare("v0.2.4", "0.2.4") == :ok
  end

  test "something that is not a version tag is rejected rather than guessed at" do
    for tag <- ["main", "release", "v1.2", "1.2.3.4", "vnext", ""] do
      assert {:error, message} = Check.check([tag])
      assert message =~ "not a version tag"
    end
  end

  test "a pre-release tag is a version tag" do
    assert Check.compare("v1.2.3-rc.1", "1.2.3-rc.1") == :ok
  end

  test "every tag already on HEAD agrees with the declared version" do
    # A no-op on an untagged commit, and the guard that would have caught
    # v0.2.4 if it had existed.
    assert Check.check([]) == :ok
  end
end
