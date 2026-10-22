defmodule RengaWeb.ExportLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.OrganizationExport

  defp member_conn(conn, role) do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, organization, user}
  end

  test "an owner exports the organization and downloads the archive", %{conn: conn} do
    {conn, organization, user} = member_conn(conn, "owner")

    {:ok, view, _html} = live(conn, ~p"/settings/export")
    assert has_element?(view, "#export-list", "No exports yet.")

    view
    |> form("#export-form", export: %{history: "true"})
    |> render_submit()

    export = Repo.get_by!(OrganizationExport, organization_id: organization.id)
    assert export.parts == ["history"]

    assert has_element?(view, "#export-#{export.id}-status[data-status=ready]")
    assert has_element?(view, "#export-#{export.id}", user.email)
    assert has_element?(view, "#export-#{export.id}", "with history")

    download = get(conn, ~p"/settings/export/#{export.id}/download")

    assert download.status == 200
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ ~s(attachment; filename="#{organization.slug}-)

    assert get_resp_header(download, "cache-control") == ["no-store"]

    path = Path.join(System.tmp_dir!(), "export-live-#{System.unique_integer([:positive])}")
    File.write!(path, download.resp_body)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, archive} = Archive.open(path)
    assert archive.manifest["organization"]["slug"] == organization.slug
    Archive.close(archive)

    assert Repo.exists?(
             from event in ChangeEvent,
               where:
                 event.organization_id == ^organization.id and event.kind == "export_downloaded"
           )
  end

  test "revoking an export deletes it and stops its download", %{conn: conn} do
    {conn, organization, _user} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/export")
    view |> form("#export-form") |> render_submit()

    export = Repo.get_by!(OrganizationExport, organization_id: organization.id)
    view |> element("#revoke-export-#{export.id}-confirm") |> render_click()

    assert has_element?(view, "#export-#{export.id}-status[data-status=revoked]")
    refute has_element?(view, "#export-#{export.id}-download")

    refused = get(conn, ~p"/settings/export/#{export.id}/download")
    assert redirected_to(refused) == ~p"/settings/export"
  end

  test "a second export waits for the running one", %{conn: conn} do
    {conn, organization, _user} = member_conn(conn, "owner")
    Repo.insert!(%OrganizationExport{organization_id: organization.id, status: "running"})

    {:ok, view, _html} = live(conn, ~p"/settings/export")
    html = view |> form("#export-form") |> render_submit()

    assert html =~ "An export is already running."
  end

  test "people who cannot export see neither exports nor the form", %{conn: conn} do
    {conn, organization, _user} = member_conn(conn, "admin")
    export = Repo.insert!(%OrganizationExport{organization_id: organization.id, status: "ready"})

    {:ok, view, _html} = live(conn, ~p"/settings/export")

    assert has_element?(view, "#export-owners-only")
    refute has_element?(view, "#export-form")
    refute has_element?(view, "#export-list")

    refused = get(conn, ~p"/settings/export/#{export.id}/download")
    assert redirected_to(refused) == ~p"/settings/export"
  end

  test "an owner who loses the role mid-session is refused", %{conn: conn} do
    {conn, organization, user} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/export")

    OrganizationMembership
    |> where([m], m.organization_id == ^organization.id and m.user_id == ^user.id)
    |> Repo.update_all(set: [role: "admin"])

    html = view |> form("#export-form") |> render_submit()

    assert html =~ "You can no longer export this organization."
    refute has_element?(view, "#export-form")
    refute Repo.exists?(OrganizationExport)
  end
end
