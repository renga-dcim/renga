defmodule RengaWeb.PrefixEditLiveTest do
  @moduledoc """
  Creating, editing, and deleting prefixes from the Network area (RFD 4,
  Phase 1): owners and admins only, with the routing table's uniqueness
  surfaced in the form.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory.Prefix
  alias Renga.Repo

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    %{admin_conn: admin_conn, admin: admin, member_conn: member_conn}
  end

  describe "creating" do
    test "an admin creates a prefix and lands on its table and family", context do
      blue = vrf_fixture(context.admin, "blue")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes?family=ipv4")

      assert has_element?(view, "#new-prefix")

      view
      |> form("#prefix-form",
        prefix: %{prefix: "2001:db8:b::/48", vrf_id: blue.id, status: "container"}
      )
      |> render_submit()

      created = Repo.get_by!(Prefix, vrf_id: blue.id, status: "container")
      assert_patch(view, ~p"/network/prefixes?family=ipv6&vrf=blue")
      assert has_element?(view, "#flash-info", "Prefix 2001:db8:b::/48 created")
      assert has_element?(view, "#prefix-row-#{created.id}")
    end

    test "the form explains an invalid or duplicate CIDR", context do
      prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes")

      view |> form("#prefix-form", prefix: %{prefix: "10.0.0.1/24"}) |> render_change()
      assert has_element?(view, "#prefix-form", "is invalid")

      view |> form("#prefix-form", prefix: %{prefix: "10.0.0.0/24"}) |> render_submit()
      assert has_element?(view, "#prefix-form", "already exists in this routing table")
      assert Repo.aggregate(Prefix, :count) == 1
    end

    test "members see no create control and cannot create one", context do
      {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes")

      refute has_element?(view, "#new-prefix")
      refute has_element?(view, "#prefix-form")

      render_hook(view, "create_prefix", %{"prefix" => %{"prefix" => "10.9.0.0/24"}})
      assert has_element?(view, "#flash-error", "Only owners and admins manage prefixes")
      assert Repo.aggregate(Prefix, :count) == 0
    end
  end

  describe "editing and deleting" do
    test "an admin edits a prefix in place", context do
      prefix = prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{prefix}")

      view
      |> form("#prefix-edit-form", prefix: %{status: "reserved", description: "Lab"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "Prefix updated")

      assert has_element?(
               view,
               "#prefix-record[href='/inventory/#{prefix.resource_id}']",
               "Open in Inventory"
             )

      assert has_element?(view, "#prefix-detail", "Reserved")
      assert %{status: "reserved", description: "Lab"} = Repo.get!(Prefix, prefix.id)
    end

    test "an admin moves a prefix into a VRF picked from the list", context do
      blue = vrf_fixture(context.admin, "blue")
      prefix = prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{prefix}")

      assert has_element?(view, "#prefix-edit-form option[value='#{blue.id}']", "blue")

      view |> form("#prefix-edit-form", prefix: %{vrf_id: blue.id}) |> render_submit()

      assert Repo.get!(Prefix, prefix.id).vrf_id == blue.id
      assert has_element?(view, "#prefix-detail a[href='/network/prefixes?family=ipv4&vrf=blue']")

      # Back to the global table.
      view |> form("#prefix-edit-form", prefix: %{vrf_id: ""}) |> render_submit()
      assert Repo.get!(Prefix, prefix.id).vrf_id == nil
    end

    test "an edit into a CIDR the table holds stays open with the error", context do
      prefix_fixture(context.admin, "10.0.1.0/24")
      prefix = prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{prefix}")

      view |> form("#prefix-edit-form", prefix: %{prefix: "10.0.1.0/24"}) |> render_submit()

      assert has_element?(view, "#prefix-edit-form", "already exists in this routing table")
      assert Repo.get!(Prefix, prefix.id).prefix == prefix.prefix
    end

    test "an admin deletes a prefix and returns to its table", context do
      prefix = prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{prefix}")

      assert has_element?(view, "#delete-prefix-dialog", "Delete 10.0.0.0/24?")
      view |> element("#delete-prefix-dialog-confirm") |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == ~p"/network/prefixes?family=ipv4&vrf=blue"
      assert flash["info"] == "Prefix 10.0.0.0/24 deleted"
      refute Repo.get(Prefix, prefix.id)
    end

    test "a prefix deleted elsewhere sends its page back to the list", context do
      prefix = prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{prefix}")

      {:ok, _} = Renga.IPAM.delete_prefix(context.admin, prefix)
      send(view.pid, :reload)

      {path, flash} = assert_redirect(view)
      assert path == ~p"/network/prefixes"
      assert flash["error"] == "That prefix was deleted"
    end

    test "members see no edit controls and cannot edit or delete", context do
      prefix = prefix_fixture(context.admin, "10.0.0.0/24")
      {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes/#{prefix}")

      refute has_element?(view, "#edit-prefix")
      refute has_element?(view, "#delete-prefix")

      render_hook(view, "update_prefix", %{"prefix" => %{"status" => "deprecated"}})
      assert has_element?(view, "#flash-error", "Only owners and admins manage prefixes")

      render_hook(view, "delete_prefix", %{})
      assert Repo.get!(Prefix, prefix.id).status == "active"
    end
  end

  defp sign_in(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
