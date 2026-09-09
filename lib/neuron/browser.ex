defmodule Neuron.Browser do
  @moduledoc "Provider-neutral browser worker contract."
  @callback fetch(url :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  def fetch(url, opts \\ []) do
    preferred = Keyword.get(opts, :provider, Application.get_env(:neuron, :browser, [])[:preferred] || :local)
    providers = if preferred == :local, do: [:local, :browser_use], else: [preferred, :local]
    Neuron.Telemetry.span([:browser, :fetch], Neuron.Telemetry.trace_metadata(opts) |> Map.put(:url, url), fn -> attempt(providers, url, opts, []) end)
  end

  defp attempt([], _url, _opts, errors), do: {:error, {:browser_blocked, Enum.reverse(errors)}}

  defp attempt([provider | rest], url, opts, errors) do
    Neuron.Telemetry.emit([:browser, :attempt], Neuron.Telemetry.trace_metadata(opts) |> Map.merge(%{provider: provider, url: url}))
    result = provider_module(provider).fetch(url, opts)

    case result do
      {:ok, snapshot} -> {:ok, Map.put(snapshot, :provider, provider)}
      {:error, reason} ->
        Neuron.Telemetry.emit([:browser, :blocked], %{provider: provider, url: url, reason: inspect(reason)})
        attempt(rest, url, opts, [{provider, reason} | errors])
    end
  end

  defp provider_module(:local), do: Neuron.Browser.Local
  defp provider_module(:browser_use), do: Neuron.Browser.BrowserUse
  defp provider_module(module) when is_atom(module), do: module
end

defmodule Neuron.Browser.Local do
  @behaviour Neuron.Browser
  @impl true
  def fetch(url, opts) do
    if Code.ensure_loaded?(Pinocchio.Browser) do
      case apply(Pinocchio.Browser, :start_session, []) do
        {:ok, session} ->
          try do
            _ = apply(Pinocchio.Browser, :visit_and_wait, [session, url, [timeout: Keyword.get(opts, :timeout, 30_000)]])
            {:ok, %{url: apply(Pinocchio.Browser, :current_url, [session]), title: apply(Pinocchio.Browser, :page_title, [session]), html: apply(Pinocchio.Browser, :page_source, [session])}}
          rescue
            error -> {:error, {:local_browser_error, Exception.message(error)}}
          after
            _ = apply(Pinocchio.Browser, :end_session, [session])
          end
        {:error, reason} -> {:error, {:local_browser_start, reason}}
      end
    else
      {:error, :pinocchio_unavailable}
    end
  end
end

defmodule Neuron.Browser.BrowserUse do
  @behaviour Neuron.Browser
  @impl true
  def fetch(url, opts) do
    config = Application.get_env(:neuron, :browser, [])[:browser_use] || []
    key = config[:api_key] || System.get_env("BROWSER_USE_API_KEY")

    cond do
      is_nil(key) or key == "" -> {:error, :browser_use_not_configured}
      not Code.ensure_loaded?(Req) -> {:error, :req_unavailable}
      true ->
        endpoint = config[:endpoint] || "https://api.browser-use.com/api/v1/browsers"
        headers = [{"x-browser-use-api-key", key}, {"content-type", "application/json"}]

        case apply(Req, :post, [endpoint, [headers: headers, json: %{task: "Open #{url} and return the page", url: url}, receive_timeout: Keyword.get(opts, :timeout, 60_000)]]) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, %{url: body["url"] || url, title: body["title"] || "", html: body["html"] || body["content"] || "", remote_id: body["id"]}}
          {:ok, %{status: status, body: body}} -> {:error, {:browser_use_http, status, body}}
          {:error, reason} -> {:error, {:browser_use_transport, reason}}
        end
    end
  end
end
