defmodule RengaWeb.RecoveryMode do
  @moduledoc """
  Fail-closed recovery mode (RFD 15, "Local sign-in policy"). While local
  sign-in is disabled and no deployment provider is usable, nobody can sign
  in, so browser routes serve only the recovery page and the provider test
  links an operator uses to activate a provider. The agent API is not
  affected.

  The plug guards requests. A LiveView connects and navigates over its
  socket without them, and can outlive the moment recovery mode begins, such
  as an override being revoked or expiring, so `on_mount/4` guards every
  browser live session too: at mount, and again before each event, params
  change, message, and async result.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Renga.Accounts.SignInPolicy

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      allowed?(conn.path_info) ->
        conn

      not active?() ->
        conn

      conn.method in ["GET", "HEAD"] ->
        conn |> Phoenix.Controller.redirect(to: "/recovery") |> halt()

      true ->
        conn |> send_resp(503, "Renga is in recovery mode.") |> halt()
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    cond do
      socket.view == RengaWeb.RecoveryLive ->
        {:cont, socket}

      active?() ->
        {:halt, to_recovery(socket)}

      true ->
        {:cont,
         socket
         |> attach_hook(:recovery_mode, :handle_event, fn _event, _params, socket ->
           guard(socket)
         end)
         |> attach_hook(:recovery_mode, :handle_params, fn _params, _uri, socket ->
           guard(socket)
         end)
         |> attach_hook(:recovery_mode, :handle_info, fn _message, socket -> guard(socket) end)
         |> attach_hook(:recovery_mode, :handle_async, fn _name, _result, socket ->
           guard(socket)
         end)}
    end
  end

  defp guard(socket), do: if(active?(), do: {:halt, to_recovery(socket)}, else: {:cont, socket})

  defp to_recovery(socket), do: Phoenix.LiveView.redirect(socket, to: "/recovery")

  # The usual case, local sign-in enabled by the environment, reads no
  # database.
  defp active?,
    do: not SignInPolicy.configured_local_sign_in?() and SignInPolicy.recovery_mode?()

  defp allowed?(["recovery"]), do: true
  defp allowed?(["users", "providers", "test", _token]), do: true
  defp allowed?(["users", "auth", _provider, "callback"]), do: true
  defp allowed?(_path), do: false
end
