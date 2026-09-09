defmodule Neuron.SnapshotTest do
  use ExUnit.Case, async: true

  test "removes executable and boilerplate markup and returns markdown metadata" do
    assert {:ok, snapshot} = Neuron.Snapshot.from_html("<html><script>alert(1)</script><main><h1>Lead</h1><p>Useful text</p></main></html>", %{url: "https://example.test"})
    assert snapshot.markdown =~ "Lead"
    refute snapshot.markdown =~ "alert"
    assert is_binary(snapshot.content_hash)
  end
end
