defmodule RengaWeb.OperatorAuth do
  @moduledoc """
  Authenticates operator API requests with an operator token (RFD 22).

  This path is separate from user sessions and intake keys. While no token
  could authenticate, the API is off and answers every request with `404`, as
  if it were not there. Otherwise each request must carry a bearer token
  that is unrevoked, unexpired, and used from an allowed address.

  The address is the connection's peer. Forwarding headers are never read
  here, so a proxy in front of this listener must preserve the client
  address at the connection level or tokens must not restrict sources.
  """

  @behaviour Plug

  import Plug.Conn

  alias Renga.Operators

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with true <- Operators.enabled?(),
         {:ok, plaintext} <- bearer_token(conn),
         {:ok, token} <- Operators.authenticate(plaintext, conn.remote_ip) do
      assign(conn, :operator_token, token)
    else
      false ->
        conn |> send_error(404, "not_found") |> halt()

      _error ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_error(401, "unauthorized")
        |> halt()
    end
  end

  @doc """
  Function plug that refuses a request whose token lacks `scope` with `403`.
  """
  def require_scope(%{assigns: %{operator_token: token}} = conn, scope) do
    if Operators.authorized?(token, scope) do
      conn
    else
      conn |> send_error(403, "forbidden") |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> plaintext] -> {:ok, String.trim(plaintext)}
      _other -> :error
    end
  end

  defp send_error(conn, status, error) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: error})
  end
end
