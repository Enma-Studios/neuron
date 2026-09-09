defmodule Neuron.Browser.Fleet do
  @moduledoc """
  Page-saturated browsing across a handful of browser sessions.

  Concurrency scales with concurrent pages per browser, not browser count:
  the fleet opens a small number of browser sessions and multiplexes many
  tabs on each. Tabs opened on one session share its browser context, so a
  logged-in Browser Use profile applies to every page of that session.
  """

  defstruct [:handles, :opts]

  @default_opts [sessions: 2, pages_per_session: 8, timeout: 45_000]

  @doc "Open a fleet of Browser Use cloud browser sessions."
  def open(opts \\ []) do
    opts = resolve_opts(opts)
    count = Keyword.fetch!(opts, :sessions)

    {handles, failures} =
      Enum.reduce(1..count, {[], []}, fn index, {handles, failures} ->
        case open_session(opts) do
          {:ok, handle} -> {[handle | handles], failures}
          {:error, reason} -> {handles, [{index, reason} | failures]}
        end
      end)

    handles = Enum.reverse(handles)

    Neuron.Telemetry.emit(
      [:browser, :fleet],
      Neuron.Telemetry.trace_metadata(opts)
      |> Map.merge(%{sessions: count, opened: length(handles), failures: inspect(failures)})
    )

    if handles == [],
      do: {:error, {:fleet_no_sessions, Enum.reverse(failures)}},
      else: {:ok, %__MODULE__{handles: handles, opts: opts}}
  end

  @doc "Release every fleet session back to its provider."
  def close(%__MODULE__{handles: handles, opts: opts}) do
    Enum.each(handles, &close_handle/1)

    Neuron.Telemetry.emit(
      [:browser, :fleet_close],
      Neuron.Telemetry.trace_metadata(opts) |> Map.merge(%{closed: length(handles)})
    )

    :ok
  end

  @doc """
  Run `fun` with an open fleet, guaranteeing teardown. Pass `:handles` to
  supply already-open sessions instead of provisioning new ones.
  """
  def with_fleet(opts \\ [], fun) when is_function(fun, 1) do
    if handles = Keyword.get(opts, :handles) do
      fun.(%__MODULE__{handles: handles, opts: resolve_opts(opts)})
    else
      case open(opts) do
        {:ok, fleet} ->
          try do
            fun.(fleet)
          after
            close(fleet)
          end

        error ->
          error
      end
    end
  end

  @doc """
  Fetch every task page on the fleet, running `sessions * pages_per_session`
  pages concurrently. Each task is `%{id: term(), url: String.t()}`; results
  come back as `[{id, {:ok, page} | {:error, reason}}]`.
  """
  def fetch_pages(%__MODULE__{handles: handles, opts: opts}, tasks),
    do: fetch_pages(handles, tasks, opts)

  def fetch_pages(handles, tasks, opts) when is_list(handles) and is_list(tasks) do
    opts = resolve_opts(opts)
    pages = Keyword.fetch!(opts, :pages_per_session)
    slots = length(handles) * pages

    if slots == 0 or tasks == [] do
      []
    else
      adapter = Keyword.get(opts, :page_adapter, Neuron.Browser.Fleet.CDP)

      tasks
      |> Enum.with_index()
      |> Enum.group_by(fn {_task, index} -> rem(index, slots) end, fn {task, _index} -> task end)
      |> Enum.map(fn {slot, slot_tasks} ->
        Task.async(fn -> run_slot(slot, slot_tasks, handles, pages, adapter, opts) end)
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))
    end
  end

  defp run_slot(slot, tasks, handles, pages, adapter, opts) do
    handle = Enum.at(handles, div(slot, pages))

    Enum.map(tasks, fn task ->
      Neuron.Telemetry.emit(
        [:browser, :page],
        Neuron.Telemetry.trace_metadata(opts)
        |> Map.merge(%{provider: handle.provider, url: task.url, session: div(slot, pages)})
      )

      {task.id,
       try do
         adapter.run_page(handle, task, opts)
       rescue
         error -> {:error, {:page_error, Exception.message(error)}}
       end}
    end)
  end

  defp resolve_opts(opts) do
    @default_opts
    |> Keyword.merge(Application.get_env(:neuron, :browser, [])[:fleet] || [])
    |> Keyword.merge(opts)
  end

  defp open_session(opts), do: Neuron.Browser.BrowserUse.open_session(opts)

  defp close_handle(handle), do: Neuron.Browser.BrowserUse.close_session(handle)
end

defmodule Neuron.Browser.Fleet.CDP do
  @moduledoc """
  Default page runner: one CDP tab per task on the slot's session.

  Readiness is polled per page instead of awaiting session-wide load
  events, which any concurrent tab on the same session can trigger.
  """

  @poll_interval 250
  @minimal_source 256

  def run_page(handle, task, opts) do
    timeout = Keyword.get(opts, :timeout, 45_000)
    page = Pinocchio.Browser.new_page(handle.session)

    try do
      _ = Pinocchio.Browser.visit(page, task.url)

      with :ok <- wait_ready(page, task.url, timeout) do
        {:ok,
         %{
           provider: handle.provider,
           url: Pinocchio.Browser.current_url(page),
           title: Pinocchio.Browser.page_title(page),
           html: Pinocchio.Browser.page_source(page)
         }}
      end
    after
      _ = Pinocchio.Browser.close_page(page)
    end
  end

  @doc """
  Poll until the page reports the target host and its source stops
  changing. Load events cannot be used here: any concurrent tab on the
  same session can trigger them. A page that never settles is an error,
  not a partial result.
  """
  @spec wait_ready(term(), String.t(), timeout()) :: :ok | {:error, :page_not_ready}
  def wait_ready(page, url, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_ready(page, url, deadline, nil)
  end

  defp poll_ready(page, url, deadline, previous_size) do
    size = page |> Pinocchio.Browser.page_source() |> byte_size()
    expected_host = host_of(url)

    ready? =
      is_nil(expected_host) or
        (host_of(Pinocchio.Browser.current_url(page)) == expected_host and
           settled?(size, previous_size))

    cond do
      ready? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :page_not_ready}

      true ->
        Process.sleep(@poll_interval)
        poll_ready(page, url, deadline, size)
    end
  end

  defp settled?(size, previous_size),
    do: is_integer(previous_size) and size == previous_size and size > @minimal_source

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end
end
