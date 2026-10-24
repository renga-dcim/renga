defmodule RengaWeb.ExportController do
  @moduledoc """
  Serves an organization export's archive (RFD 20). Each download rechecks
  `organization.export` and is recorded in Activity before the first byte
  is sent.
  """
  use RengaWeb, :controller

  alias Renga.Transfers

  def download(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case scope.organization_id && Transfers.authorize_download(scope, id) do
      {:ok, export} ->
        send_archive(conn, scope.organization, export)

      _refused ->
        conn
        |> put_flash(:error, "That export is no longer available to you.")
        |> redirect(to: ~p"/settings/export")
    end
  end

  defp send_archive(conn, organization, export) do
    filename =
      "#{organization.slug}-#{Calendar.strftime(export.snapshot_at, "%Y%m%d-%H%M%S")}.tar.zst"

    conn =
      conn
      |> put_resp_content_type("application/zstd", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> put_resp_header("content-length", Integer.to_string(export.bytes))
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    case Enum.reduce_while(Transfers.chunks(export), {conn, 0}, &send_chunk/2) do
      {conn, :closed} ->
        conn

      {conn, sent} when sent == export.bytes ->
        conn

      # A revocation or expiry deleted the rest of the archive mid-download.
      # The response promised every byte, and ending it normally would keep
      # the connection open for bytes that never come; raising closes it, so
      # the client sees a failed download.
      {_conn, sent} ->
        raise "export #{export.id} was removed after #{sent} of #{export.bytes} bytes were sent"
    end
  end

  # The client went away; stop reading chunks.
  defp send_chunk(data, {conn, sent}) do
    case chunk(conn, data) do
      {:ok, conn} -> {:cont, {conn, sent + byte_size(data)}}
      {:error, _closed} -> {:halt, {conn, :closed}}
    end
  end
end
