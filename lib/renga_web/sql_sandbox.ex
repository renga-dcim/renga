defmodule RengaWeb.SQLSandbox do
  @moduledoc """
  Joins connected LiveViews to the browser test that opened them.

  `Phoenix.Ecto.SQL.Sandbox` in the endpoint covers plain HTTP requests, but a
  LiveView runs in its own process after the WebSocket connects. This hook
  reads the same User-Agent metadata from the socket and allows the LiveView
  to use the test's database transaction.

  Outside test builds `:sql_sandbox` is unset and the hook does nothing.
  """

  import Phoenix.LiveView

  @sandbox Application.compile_env(:renga, :sql_sandbox)

  def on_mount(:default, _params, _session, socket) do
    if @sandbox && connected?(socket) do
      socket
      |> get_connect_info(:user_agent)
      |> Phoenix.Ecto.SQL.Sandbox.allow(@sandbox)
    end

    {:cont, socket}
  end
end
