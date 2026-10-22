defmodule RengaWeb.Scim.UserController do
  @moduledoc """
  The SCIM `Users` endpoint (RFD 16, "Endpoints"): create, read, replace,
  patch, delete, and list a connection's directory entries.
  """

  use RengaWeb, :controller

  alias Renga.Scim.Users
  alias RengaWeb.Scim.Response
  alias RengaWeb.Scim.UserJSON

  def index(conn, params) do
    with {:ok, {start_index, count}} <- Response.page(params),
         {:ok, {total, users}} <-
           Users.list(conn.assigns.scim_connection, params["filter"], start_index, count) do
      Response.list(conn, total, start_index, Enum.map(users, &UserJSON.render/1))
    else
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case Users.get(conn.assigns.scim_connection, id) do
      nil -> Response.failure(conn, :not_found)
      user -> Response.json(conn, 200, UserJSON.render(user))
    end
  end

  def create(conn, _params) do
    case Users.create(Response.client(conn), conn.body_params) do
      {:ok, user} ->
        conn
        |> put_resp_header("location", UserJSON.location(user))
        |> Response.json(201, UserJSON.render(user))

      {:error, reason} ->
        Response.failure(conn, reason)
    end
  end

  def update(conn, %{"id" => id}) do
    conn
    |> Response.client()
    |> Users.replace(id, conn.body_params)
    |> respond(conn)
  end

  def patch(conn, %{"id" => id}) do
    with {:ok, operations} <- Response.operations(conn.body_params),
         {:ok, user} <- Users.patch(Response.client(conn), id, operations) do
      Response.json(conn, 200, UserJSON.render(user))
    else
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Users.delete(Response.client(conn), id) do
      {:ok, _user} -> send_resp(conn, 204, "")
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  defp respond({:ok, user}, conn), do: Response.json(conn, 200, UserJSON.render(user))
  defp respond({:error, reason}, conn), do: Response.failure(conn, reason)
end
