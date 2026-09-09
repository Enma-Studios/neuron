defmodule Neuron.Browser.Fleet.Target do
  @moduledoc """
  CDP tab lifecycle over Pinocchio's asynchronous command path.

  `Pinocchio.Browser.new_page/close_page` drive `Target.*` commands through
  the connection's synchronous reply loop, which stalls once tabs are
  created and closed concurrently — every subsequent create then waits out
  a 15 second timeout. Regular page commands flow through the connection's
  mailbox asynchronously and are proven reliable, so tabs are created,
  attached, and closed with the same async commands.
  """

  @command_timeout 15_000

  @doc "Open a tab in the session's default browser context; returns a %Pinocchio.Page{}."
  def open(%Pinocchio.Session{pid: pid} = session) do
    with {:ok, %{"targetId" => target_id}} <-
           command(pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session_id}} <-
           command(pid, "Target.attachToTarget", %{targetId: target_id, flatten: true}) do
      %Pinocchio.Page{session: session, target_id: target_id, session_id: session_id}
    else
      {:error, reason} -> raise "target open failed: #{inspect(reason)}"
    end
  end

  @doc "Close a tab opened by `open/1`."
  def close(%Pinocchio.Page{
        session: %Pinocchio.Session{pid: pid},
        target_id: target_id,
        session_id: session_id
      }) do
    _ = command(pid, "Target.detachFromTarget", %{sessionId: session_id})
    command(pid, "Target.closeTarget", %{targetId: target_id})
    :ok
  end

  defp command(pid, method, params),
    do: Pinocchio.Session.command(pid, method, params, @command_timeout)
end
