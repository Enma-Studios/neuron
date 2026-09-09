defmodule Neuron.SnapshotTest do
  use ExUnit.Case, async: true

  test "removes executable and boilerplate markup and returns markdown metadata" do
    assert {:ok, snapshot} =
             Neuron.Snapshot.from_html(
               "<html><script>alert(1)</script><main><h1>Lead</h1><p>Useful text</p></main></html>",
               %{url: "https://example.test"}
             )

    assert snapshot.markdown =~ "Lead"
    refute snapshot.markdown =~ "alert"
    assert is_binary(snapshot.content_hash)
  end

  test "wraps in-browser markdown with hash and extraction version" do
    {:ok, snapshot} =
      Neuron.Snapshot.from_markdown("# Team\n\nAda is CTO.", %{url: "https://x.example"})

    assert snapshot.markdown == "# Team\n\nAda is CTO."
    assert snapshot.extraction_version == 2

    assert snapshot.content_hash ==
             :crypto.hash(:sha256, "# Team\n\nAda is CTO.") |> Base.encode16(case: :lower)
  end
end
