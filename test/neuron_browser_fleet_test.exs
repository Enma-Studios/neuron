defmodule Neuron.Browser.FleetTest do
  use ExUnit.Case, async: true

  defmodule RecordingAdapter do
    def run_page(handle, task, _opts) do
      send(task.test_pid, {:run, task.id, handle.name, self()})

      if task.id == :boom do
        {:error, :exploded}
      else
        {:ok, %{provider: :fake, url: task.url, title: "page", html: "<html></html>"}}
      end
    end
  end

  defp tasks(ids) do
    for id <- ids, do: %{id: id, url: "https://example.com/#{id}", test_pid: self()}
  end

  test "spreads tasks over every session times pages slot" do
    handles = [
      %{provider: :fake, name: :a, session: nil},
      %{provider: :fake, name: :b, session: nil}
    ]

    ids = Enum.to_list(1..20)
    slots = 6

    results =
      Neuron.Browser.Fleet.fetch_pages(handles, tasks(ids),
        pages_per_session: 3,
        page_adapter: RecordingAdapter
      )

    assert length(results) == 20

    assert Enum.all?(results, fn
             {id, {:ok, page}} -> page.url == "https://example.com/#{id}"
             {_, {:error, _}} -> false
           end)

    runs = receive_all()

    # Every slot runs on its own process: six slots, all saturated.
    slot_pids = runs |> Enum.map(fn {_, _, pid} -> pid end) |> Enum.uniq()
    assert length(slot_pids) == slots

    # Tasks stay pinned to one slot process, and each slot maps to one
    # session: slots 0-2 belong to :a, slots 3-5 to :b.
    by_pid = Enum.group_by(runs, fn {_, _, pid} -> pid end, fn {id, _, _} -> id end)

    assert Enum.all?(by_pid, fn {_pid, slot_ids} ->
             rems = slot_ids |> Enum.map(fn id -> slot_of(id, slots) end) |> Enum.uniq()
             length(rems) == 1
           end)

    assert Enum.all?(runs, fn {_id, handle, _pid} ->
             handle in [:a, :b]
           end)

    for {id, handle, _pid} <- runs do
      slot = slot_of(id, slots)
      expected = if slot < 3, do: :a, else: :b
      assert handle == expected
    end
  end

  test "isolates per-page failures inside a slot" do
    handles = [%{provider: :fake, name: :a, session: nil}]

    results =
      Neuron.Browser.Fleet.fetch_pages(handles, tasks([:boom, :fine, :also_fine]),
        pages_per_session: 2,
        page_adapter: RecordingAdapter
      )

    assert {:boom, {:error, :exploded}} in results
    assert match?({:ok, _}, Keyword.get(results, :fine))
    assert match?({:ok, _}, Keyword.get(results, :also_fine))
  end

  test "returns nothing without tasks or slots" do
    handles = [%{provider: :fake, name: :a, session: nil}]
    assert Neuron.Browser.Fleet.fetch_pages(handles, [], pages_per_session: 2) == []
    assert Neuron.Browser.Fleet.fetch_pages([], tasks([:x]), pages_per_session: 2) == []
  end

  test "with_fleet uses supplied handles directly" do
    handles = [%{provider: :fake, name: :a, session: nil}]

    result =
      Neuron.Browser.Fleet.with_fleet(
        [handles: handles, pages_per_session: 2, page_adapter: RecordingAdapter],
        fn fleet -> {:captured, fleet} end
      )

    assert {:captured, %{handles: [%{name: :a}]}} = result
  end

  defp slot_of(id, slots) when is_integer(id), do: rem(id - 1, slots)

  defp receive_all(acc \\ []) do
    receive do
      {:run, id, handle, pid} -> receive_all([{id, handle, pid} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
