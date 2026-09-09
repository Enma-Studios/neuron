defmodule Neuron.Browser do
  @moduledoc "Browser Use cloud browsing contract."
  @callback fetch(url :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  def fetch(url, opts \\ []) do
    providers = [Keyword.get(opts, :provider, :browser_use)]

    Neuron.Telemetry.span(
      [:browser, :fetch],
      Neuron.Telemetry.trace_metadata(opts) |> Map.put(:url, url),
      fn -> attempt(providers, url, opts, []) end
    )
  end

  defp attempt([], _url, _opts, errors), do: {:error, {:browser_blocked, Enum.reverse(errors)}}

  defp attempt([provider | rest], url, opts, errors) do
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

        attempt(rest, url, opts, [{provider, reason} | errors])
    end
  end

  defp provider_module(:browser_use), do: Neuron.Browser.BrowserUse
  defp provider_module(module) when is_atom(module), do: module
end

defmodule Neuron.Browser.BrowserUse do
  @behaviour Neuron.Browser

  @doc "Returns the configured Browser Use profile ID sent to every new cloud session."
  def profile_id(opts \\ []) do
    config = Application.get_env(:neuron, :browser, [])[:browser_use] || []

    id =
      Keyword.get(
        opts,
        :browser_use_profile_id,
        config[:profile_id] || System.get_env("BROWSER_USE_PROFILE_ID")
      )

    id
  end

  @impl true
  def fetch(url, opts) do
    config = Application.get_env(:neuron, :browser, [])[:browser_use] || []
    key = config[:api_key] || System.get_env("BROWSER_USE_API_KEY")

    cond do
      is_nil(key) or key == "" ->
        {:error, :browser_use_not_configured}

      not Code.ensure_loaded?(Req) ->
        {:error, :req_unavailable}

      true ->
        fetch_with_open_session(url, opts)
    end
  end

  @doc """
  Provision one cloud browser session for multi-page use. The caller owns
  the returned handle and must release it with `close_session/1`.
  """
  def open_session(opts \\ []) do
    config = Application.get_env(:neuron, :browser, [])[:browser_use] || []
    key = config[:api_key] || System.get_env("BROWSER_USE_API_KEY")

    cond do
      is_nil(key) or key == "" ->
        {:error, :browser_use_not_configured}

      not Code.ensure_loaded?(Req) ->
        {:error, :req_unavailable}

      true ->
        open_pinocchio_session(config, key, opts)
    end
  end

  def close_session(%{pid: pid, prepared: prepared}) do
    _ = Pinocchio.Session.release(pid)
    _ = Pinocchio.Providers.BrowserUse.stop(prepared[:provider_session])
    Process.exit(pid, :shutdown)
    :ok
  end

  defp fetch_with_open_session(url, opts) do
    with {:ok, handle} <- open_session(opts) do
      session = handle.session

      try do
        _ =
          Pinocchio.Browser.visit_and_wait(session, url,
            timeout: Keyword.get(opts, :timeout, 60_000)
          )

        {:ok,
         %{
           url: Pinocchio.Browser.current_url(session),
           title: Pinocchio.Browser.page_title(session),
           html: Pinocchio.Browser.page_source(session)
         }}
      rescue
        error -> {:error, {:browser_use_error, Exception.message(error)}}
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

      {:ok,
       %{
         pid: pid,
         provider: :browser_use,
         session: %Pinocchio.Session{pid: pid},
         prepared: prepared
       }}
    else
      {:error, reason} -> {:error, {:browser_use_start, reason}}
    end
  end

  defp maybe_put_profile_id(config, id) when is_binary(id) and id != "" do
    Map.put(config, :profile_id, id)
  end

  defp maybe_put_profile_id(config, _id), do: config
end
