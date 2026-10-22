defmodule RengaWeb.Scim.Auth do
  @moduledoc """
  Authenticates SCIM requests with a connection's bearer token (RFD 16,
  "Connections"). The token selects the connection, and so the
  organization; nothing else, including a browser session, reaches the SCIM
  endpoints.
  """

  @behaviour Plug

  import Plug.Conn

  alias Renga.Scim
  alias RengaWeb.Scim.Response

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, value} <- bearer_token(conn),
         {:ok, connection, token} <- Scim.authenticate(value) do
      :ok = Scim.touch_token(token)
      Logger.metadata(scim_connection_id: connection.id)

      conn
      |> assign(:scim_connection, connection)
      |> assign(:scim_token, token)
    else
      _invalid ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="scim"))
        |> Response.error(401, "The bearer token is invalid or missing")
        |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] when token != "" ->
            if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}, else: :error

          _other ->
            :error
        end

      _missing_or_repeated ->
        :error
    end
  end
end
