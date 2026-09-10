defmodule Mix.Tasks.Neuron.Browser.Sweep do
  use Mix.Task
  @shortdoc "Stop Browser Use sessions still running past the configured TTL"
  @moduledoc """
  Run `mix neuron.browser.sweep` to reconcile the provider against reality.

  A session that outlived its run is billed until the provider's own
  timeout expires, so this task lists every browser the API key has and
  stops the ones still running past `session_ttl_seconds`. Pass a TTL in
  seconds to override the configured one.
  """
  # Configuration only: a leaked session must be reclaimable even when the
  # application itself will not start.
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    opts =
      case args do
        [ttl] -> [session_ttl_seconds: String.to_integer(ttl)]
        _ -> []
      end

    case Neuron.Browser.BrowserUse.sweep(opts) do
      {:ok, []} ->
        Mix.shell().info("No sessions older than the TTL are still running.")

      {:ok, ids} ->
        Mix.shell().info("Stopped #{length(ids)} session(s): #{Enum.join(ids, ", ")}")

      {:error, reason} ->
        Mix.raise("browser sweep failed: #{inspect(reason)}")
    end
  end
end
