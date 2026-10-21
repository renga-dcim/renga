defmodule RengaWeb.RecoveryMode do
  @moduledoc """
  Fail-closed recovery mode (RFD 15, "Local sign-in policy"). While local
  sign-in is disabled and no deployment provider is usable, nobody can sign
  in, so browser routes serve only the recovery page and the provider test
  links an operator uses to activate a provider. The agent API is not
  affected.
  """

  @behaviour Plug

  import Plug.Conn

  alias Renga.Accounts.SignInPolicy

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      # The usual case reads no database.
      SignInPolicy.configured_local_sign_in?() ->
        conn

      allowed?(conn.path_info) ->
        conn

      not SignInPolicy.recovery_mode?() ->
        conn

      conn.method in ["GET", "HEAD"] ->
        conn |> Phoenix.Controller.redirect(to: "/recovery") |> halt()

      true ->
        conn |> send_resp(503, "Renga is in recovery mode.") |> halt()
    end
  end

  defp allowed?(["recovery"]), do: true
  defp allowed?(["users", "providers", "test", _token]), do: true
  defp allowed?(["users", "auth", _provider, "callback"]), do: true
  defp allowed?(_path), do: false
end
