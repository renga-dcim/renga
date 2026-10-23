defmodule RengaWeb.Scim.GroupController do
  @moduledoc """
  The SCIM `Groups` endpoint (RFD 16, "Endpoints"): create, read, replace,
  patch (including member add and remove), delete, and list a connection's
  groups. `excludedAttributes=members` leaves members out, as Entra asks.
  """

  use RengaWeb, :controller

  alias Renga.Scim.Groups
  alias RengaWeb.Scim.GroupJSON
  alias RengaWeb.Scim.Response

  def index(conn, params) do
    opts = [members: not excludes_members?(params)]

    with {:ok, {start_index, count}} <- Response.page(params),
         {:ok, {total, groups}} <-
           Groups.list(conn.assigns.scim_connection, params["filter"], start_index, count, opts) do
      Response.list(conn, total, start_index, Enum.map(groups, &GroupJSON.render/1))
    else
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  def show(conn, %{"id" => id} = params) do
    case Groups.get(conn.assigns.scim_connection, id) do
      nil -> Response.failure(conn, :not_found)
      group -> Response.json(conn, 200, render_group(group, params))
    end
  end

  def create(conn, _params) do
    case Groups.create(Response.client(conn), conn.body_params) do
      {:ok, group} ->
        conn
        |> put_resp_header("location", GroupJSON.location(group))
        |> Response.json(201, GroupJSON.render(group))

      {:error, reason} ->
        Response.failure(conn, reason)
    end
  end

  def update(conn, %{"id" => id}) do
    case Groups.replace(Response.client(conn), id, conn.body_params) do
      {:ok, group} -> Response.json(conn, 200, GroupJSON.render(group))
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  def patch(conn, %{"id" => id} = params) do
    with {:ok, operations} <- Response.operations(conn.body_params),
         {:ok, group} <- Groups.patch(Response.client(conn), id, operations) do
      Response.json(conn, 200, render_group(group, params))
    else
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Groups.delete(Response.client(conn), id) do
      {:ok, _group} -> send_resp(conn, 204, "")
      {:error, reason} -> Response.failure(conn, reason)
    end
  end

  defp render_group(group, params) do
    if excludes_members?(params),
      do: GroupJSON.render(%{group | members: %Ecto.Association.NotLoaded{}}),
      else: GroupJSON.render(group)
  end

  defp excludes_members?(%{"excludedAttributes" => excluded}) when is_binary(excluded) do
    excluded
    |> String.split(",")
    |> Enum.any?(&(&1 |> String.trim() |> String.downcase() == "members"))
  end

  defp excludes_members?(_params), do: false
end
