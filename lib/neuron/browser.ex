defmodule Neuron.Browser do
  @moduledoc "Browser Use cloud browsing contract."
  @callback fetch(url :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  def fetch(url, opts \\ []) do
    provider = Keyword.get(opts, :provider, :browser_use)

    Neuron.Telemetry.span(
      [:browser, :fetch],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:url, url),
      fn ->
        Neuron.Telemetry.emit(
          [:browser, :attempt],
          Neuron.Telemetry.trace_metadata(opts) |> Map.merge(%{provider: provider, url: url})
        )

        result =
          case Keyword.get(opts, :adapter) do
            adapter when is_atom(adapter) and not is_nil(adapter) -> adapter.fetch(url, opts)
            _ -> provider_module(provider).fetch(url, opts)
          end

        case result do
          {:ok, snapshot} ->
            {:ok, Map.put(snapshot, :provider, provider)}

          {:error, reason} ->
            Neuron.Telemetry.emit(
              [:browser, :blocked],
              Neuron.Telemetry.trace_metadata(opts)
              |> Map.merge(%{provider: provider, url: url, reason: inspect(reason)})
            )

            {:error, reason}
        end
      end
    )
  end

  defp provider_module(:browser_use), do: Neuron.Browser.BrowserUse
  defp provider_module(module) when is_atom(module), do: module
end

defmodule Neuron.Browser.BrowserUse do
  @behaviour Neuron.Browser

  @defaults [session_ttl_seconds: 3600, fetch_timeout: 90_000]

  @doc """
  Browser Use settings, merged over Neuron's own defaults.

  Elixir configuration replaces a keyword rather than merging into it, so a
  host that writes `config :neuron, browser: [fleet: [...]]` silently wipes
  the `browser_use` block underneath it. A dependency's own config is never
  loaded either, so a host must declare every value it wants and is one
  partial block away from an application that browses in the parent and
  reports `:browser_use_not_configured` everywhere else. Reading through
  here rather than indexing the raw keyword means a missing block costs a
  default, not the whole configuration.
  """
  def config do
    Keyword.merge(@defaults, Application.get_env(:neuron, :browser, [])[:browser_use] || [])
  end

  @doc "The API key, from configuration first and the environment second."
  def api_key do
    present(config()[:api_key]) || present(System.get_env("BROWSER_USE_API_KEY"))
  end

  @doc "Whether a browser session can be opened at all."
  def configured?, do: not is_nil(api_key())

  @doc "Returns the configured Browser Use profile ID sent to every new cloud session."
  def profile_id(opts \\ []) do
    Keyword.get(
      opts,
      :browser_use_profile_id,
      present(config()[:profile_id]) || present(System.get_env("BROWSER_USE_PROFILE_ID"))
    )
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # One place that reports it, naming both places it looked, because a run
  # that cannot browse is otherwise indistinguishable from one that found
  # nothing.
  defp not_configured(opts) do
    Neuron.Telemetry.emit(
      [:browser, :not_configured],
      Neuron.Telemetry.trace_metadata(opts)
      |> Map.merge(%{
        checked: ":neuron, :browser, :browser_use, :api_key and BROWSER_USE_API_KEY",
        browser_config_keys: Keyword.keys(Application.get_env(:neuron, :browser, []))
      })
    )

    {:error, :browser_use_not_configured}
  end

  @impl true
  def fetch(url, opts) do
    if configured?(), do: fetch_within_deadline(url, opts), else: not_configured(opts)
  end

  @doc "The whole-fetch budget: the caller's `fetch_timeout:`, then the configured one."
  def fetch_timeout(opts), do: Keyword.get(opts, :fetch_timeout, config()[:fetch_timeout])

  # Every step inside a fetch has its own timeout, but nothing bounded their
  # sum, and one hung session held a campaign's `collect` for twenty minutes.
  # The task is killed rather than asked to stop: `Neuron.Browser.Sessions`
  # stops the remote browser of an owner that dies for any reason.
  # A kill between the provider creating a browser and `track/1`
  # registering it leaves that browser to `sweep/1`. #41.
  defp fetch_within_deadline(url, opts) do
    task = Task.async(fn -> fetch_with_open_session(url, opts) end)

    case Task.yield(task, fetch_timeout(opts)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:browser_use_error, "exit: #{inspect(reason)}"}}
      nil -> {:error, :browser_use_timeout}
    end
  end

  @doc """
  Provision one cloud browser session for multi-page use. The caller owns
  the returned handle and must release it with `close_session/1`.
  """
  def open_session(opts \\ []) do
    case api_key() do
      nil -> not_configured(opts)
      key -> open_pinocchio_session(config(), key, opts)
    end
  end

  @doc """
  Release a session handle. Cleanup is routed through
  `Neuron.Browser.Sessions` so the remote browser is stopped exactly once,
  whether the caller reaches this call or dies before it.
  """
  def close_session(handle), do: Neuron.Browser.Sessions.close(handle)

  @doc """
  Stop one session's remote browser and its local connection process.

  The remote stop runs first and unconditionally: it is the billed
  resource, and releasing a connection process that has already died must
  not be able to skip it.
  """
  def stop_session(handle) do
    provider = handle[:stop_with] || Pinocchio.Providers.BrowserUse
    _ = provider.stop(handle[:prepared][:provider_session])
    _ = record_session_usage(handle[:usage])

    if pid = handle[:pid] do
      _ = if Process.alive?(pid), do: Pinocchio.Session.release(pid)
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  @endpoint "https://api.browser-use.com/api/v4/browsers"
  @page_size 100
  @max_pages 20

  @doc """
  Every browser the provider has recorded for this API key, newest first.

  The listing pages through `pageSize`; the `limit` parameter the v4 API
  advertises is ignored and silently returns ten rows.
  """
  def list_sessions(opts \\ []) do
    case opts[:api_key] || api_key() do
      nil -> not_configured(opts)
      key -> list_pages(endpoint(opts), key, 1, [])
    end
  end

  @doc """
  Stop every provider-side browser still running past the configured TTL.

  Sessions outlive their run whenever a caller was killed before its
  cleanup path, so this is the operator's backstop against a leak that has
  already happened. Returns `{:ok, stopped_ids}`.
  """
  def sweep(opts \\ []) do
    ttl = opts[:session_ttl_seconds] || session_ttl_seconds()
    now = opts[:now] || DateTime.utc_now()

    with {:ok, sessions} <- list_sessions(opts) do
      key = opts[:api_key] || api_key()
      endpoint = endpoint(opts)

      stopped =
        for id <- stale_sessions(sessions, now, ttl) do
          :ok =
            Pinocchio.Providers.BrowserUse.stop(%{id: id, api_key: key, endpoint: endpoint})

          id
        end

      {:ok, stopped}
    end
  end

  @doc """
  The ids in `sessions` that are still running and started longer ago than
  `ttl` seconds. A session the provider has already stopped is never swept,
  however old it is.
  """
  def stale_sessions(sessions, now, ttl) do
    sessions
    |> Enum.filter(&stale?(&1, now, ttl))
    |> Enum.map(& &1["id"])
  end

  @doc "Seconds a provisioned browser may run before `sweep/1` stops it."
  def session_ttl_seconds, do: config()[:session_ttl_seconds]

  defp endpoint(opts) do
    opts[:api_endpoint] || config()[:api_endpoint] || config()[:endpoint] || @endpoint
  end

  defp stale?(session, now, ttl) do
    open? = session["status"] != "stopped" and is_nil(session["finishedAt"])

    open? and
      case DateTime.from_iso8601(session["startedAt"] || "") do
        {:ok, started, _} -> DateTime.diff(now, started) > ttl
        _ -> false
      end
  end

  defp list_pages(_endpoint, _key, page, seen) when page > @max_pages, do: {:ok, seen}

  defp list_pages(endpoint, key, page, seen) do
    query = URI.encode_query(%{"pageSize" => @page_size, "pageNumber" => page})

    case apply(Req, :get, [
           endpoint <> "?" <> query,
           [headers: [{"x-browser-use-api-key", key}], receive_timeout: 30_000]
         ]) do
      {:ok, %{status: status, body: %{"items" => items} = body}} when status in 200..299 ->
        seen = seen ++ items

        if length(seen) < (body["totalItems"] || 0) and items != [],
          do: list_pages(endpoint, key, page + 1, seen),
          else: {:ok, seen}

      {:ok, %{status: status, body: body}} ->
        {:error, {:browser_use_http, status, body}}

      {:error, reason} ->
        {:error, {:browser_use_transport, reason}}
    end
  end

  defp fetch_with_open_session(url, opts) do
    with {:ok, handle} <- open_session(opts) do
      session = handle.session

      try do
        :ok = navigate(session, url, timeout(opts))

        page = %{
          url: Pinocchio.Browser.current_url(session),
          title: Pinocchio.Browser.page_title(session),
          html: Pinocchio.Browser.page_source(session)
        }

        # Section extraction is an opt-in enhancement for interaction-heavy
        # pages; when it fails the whole-document snapshot remains the
        # document of record.
        page =
          if Keyword.get(opts, :section_extract) do
            case Neuron.Browser.Scripting.extract(session) do
              {:ok, raw} ->
                Map.merge(page, %{
                  markdown: raw["markdown"] || "",
                  section_text: raw["text"] || ""
                })

              {:error, _reason} ->
                page
            end
          else
            page
          end

        {:ok, page}
      rescue
        error -> {:error, {:browser_use_error, Exception.message(error)}}
      catch
        # A CDP call that runs past its GenServer timeout exits rather than
        # returning, and an exit is not an exception, so `rescue` never saw
        # it and it killed the caller instead of failing the fetch.
        :exit, reason -> {:error, {:browser_use_timeout, inspect(reason)}}
        kind, reason -> {:error, {:browser_use_error, "#{kind}: #{inspect(reason)}"}}
      after
        close_session(handle)
      end
    end
  end

  defp open_pinocchio_session(config, key, opts) do
    profile_id = profile_id(opts)

    browser_config =
      config
      |> Map.new()
      |> Map.put(:api_key, key)
      |> Map.put(:api_endpoint, config[:endpoint] || config[:api_endpoint])
      |> maybe_put_profile_id(profile_id)

    Neuron.Telemetry.emit(
      [:browser, :session],
      Neuron.Telemetry.trace_metadata(opts)
      |> Map.merge(%{provider: :browser_use, profile_id: profile_id})
    )

    with {:ok, prepared} <- Pinocchio.Providers.BrowserUse.prepare(browser_config),
         {:ok, pid} <- Pinocchio.Session.start_link(browser: prepared),
         :ok <- Pinocchio.Session.acquire(pid, self()) do
      Process.unlink(pid)

      handle = %{
        pid: pid,
        provider: :browser_use,
        session: %Pinocchio.Session{pid: pid},
        prepared: prepared,
        # Carried on the handle because the process that stops a session is
        # often not the one that opened it: an owner can die and the
        # cleanup owner closes it instead.
        usage: %{
          run_id: opts[:run_id],
          parent_run_id: opts[:parent_run_id],
          stage: opts[:stage],
          provider: :browser_use,
          opened_at: System.monotonic_time(:millisecond)
        }
      }

      :ok = Neuron.Browser.Sessions.track(handle)
      {:ok, handle}
    else
      {:error, reason} -> {:error, {:browser_use_start, reason}}
    end
  end

  @doc """
  Navigate and wait for the page to settle, within the caller's timeout.

  `Pinocchio.Browser.visit_and_wait/3` cannot be used here. It discards the
  timeout it is given: `expect_navigation/2` ignores its options and
  `await/1` hardcodes 30 seconds, which is below the fleet's own timeout, so
  a page allowed 120 seconds was cut off at 30. Worse, that wait is a
  `GenServer.call` and so it **exits** rather than returning an error, which
  no `with` can catch and no `rescue` will see.

  Neuron's own readiness poll takes the timeout it is given and returns
  `{:error, :page_not_ready}`, so a page that never settles fails the fetch
  instead of killing whatever was waiting on it.
  """
  def navigate(session, url, timeout) do
    _ = Pinocchio.Browser.visit(session, url)
    # `nil` rather than `url`: a direct fetch accepts wherever a redirect
    # landed, and records the final URL from the page itself.
    Neuron.Browser.Fleet.CDP.wait_ready(session, nil, timeout)
  end

  @doc "The navigation budget: the caller's, then the fleet's, then a minute."
  def timeout(opts) do
    Keyword.get(opts, :timeout) ||
      (Application.get_env(:neuron, :browser, [])[:fleet] || [])[:timeout] ||
      60_000
  end

  defp record_session_usage(%{opened_at: opened_at} = usage) do
    seconds = (System.monotonic_time(:millisecond) - opened_at) / 1000

    Neuron.Usage.record_browser(
      seconds,
      usage |> Map.delete(:opened_at) |> Map.to_list()
    )
  end

  defp record_session_usage(_usage), do: :ok

  defp maybe_put_profile_id(config, id) when is_binary(id) and id != "" do
    Map.put(config, :profile_id, id)
  end

  defp maybe_put_profile_id(config, _id), do: config
end
