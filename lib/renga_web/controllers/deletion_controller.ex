defmodule RengaWeb.DeletionController do
  @moduledoc "Owner-only recovery outside the suspended organization's ordinary UI."
  use RengaWeb, :controller
  import Phoenix.Component, only: [to_form: 1]

  alias Renga.Operators.OrganizationLifecycle
  alias Renga.Transfers

  def index(conn, _params) do
    organizations = OrganizationLifecycle.pending_for_owner(conn.assigns.current_scope.user)

    rows =
      Enum.flat_map(organizations, fn organization ->
        with {:ok, scope} <-
               OrganizationLifecycle.owner_scope(conn.assigns.current_scope.user, organization.id),
             {:ok, exports} <- Transfers.list_exports(scope) do
          [%{organization: organization, exports: exports}]
        else
          _ -> []
        end
      end)

    render(conn, :index, rows: rows, cancel_form: to_form(%{}), export_form: to_form(%{}))
  end

  def cancel(conn, %{"id" => id}) do
    [request_id] = get_resp_header(conn, "x-request-id")

    result =
      OrganizationLifecycle.cancel_by_owner(conn.assigns.current_scope.user, id, request_id)

    finish(
      conn,
      result,
      "Deletion cancelled. Organization access has been restored; cancelled work is not rerun."
    )
  end

  def export(conn, %{"id" => id}) do
    result =
      with {:ok, scope} <- OrganizationLifecycle.owner_scope(conn.assigns.current_scope.user, id) do
        Transfers.start_export(scope, [], fn -> url(~p"/organizations/deletions") end)
      end

    finish(conn, result, "Export requested. Refresh this page to download it when ready.")
  end

  def download(conn, %{"id" => id, "export_id" => export_id}) do
    case OrganizationLifecycle.owner_scope(conn.assigns.current_scope.user, id) do
      {:ok, scope} ->
        conn
        |> assign(:current_scope, scope)
        |> RengaWeb.ExportController.download(%{"id" => export_id})

      _ ->
        conn |> put_status(:forbidden) |> text("Recovery access is no longer available.")
    end
  end

  defp finish(conn, {:ok, _}, message),
    do: conn |> put_flash(:info, message) |> redirect(to: ~p"/organizations/deletions")

  defp finish(conn, {:error, _}, _message),
    do:
      conn
      |> put_flash(:error, "Recovery refused: access changed or purge has begun.")
      |> redirect(to: ~p"/organizations/deletions")
end
