defmodule RengaWeb.MemberLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory

  setup do
    organization = organization_fixture()
    {owner_conn, owner} = member(organization, "owner")
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, member} = member(organization, "member")

    %{
      owner: owner,
      owner_conn: owner_conn,
      admin: admin,
      admin_conn: admin_conn,
      member: member,
      member_conn: member_conn
    }
  end

  describe "Settings → Members" do
    test "admins change a member's role with a reason recorded in Activity", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")
      id = context.member.membership_id

      view |> element("#member-#{id}-edit") |> render_click()

      # The picker offers only roles within an admin's ceiling.
      refute has_element?(view, "#member-form option[value=owner]")
      assert has_element?(view, "#member-form option[value=viewer]")

      view
      |> form("#member-form", member: %{role: "viewer", reason: "Read-only from now on"})
      |> render_submit(%{"action" => "role"})

      assert has_element?(view, "#member-#{id}", "viewer")
      assert Accounts.get_organization_membership!(context.admin, id).role == "viewer"

      assert [%{kind: "member_role_changed", metadata: %{"reason" => "Read-only from now on"}}] =
               Inventory.list_activity(context.admin)
    end

    test "admins cannot manage owners", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")

      refute has_element?(view, "#member-#{context.owner.membership_id}-edit")
      assert has_element?(view, "#member-#{context.member.membership_id}-edit")
    end

    test "disabling and re-enabling a member", context do
      {:ok, view, _html} = live(context.owner_conn, ~p"/settings/members")
      id = context.member.membership_id

      view |> element("#member-#{id}-edit") |> render_click()

      view
      |> form("#member-form", member: %{reason: ""})
      |> render_submit(%{"action" => "disable"})

      assert has_element?(view, "#member-#{id}-status", "Disabled")

      view |> element("#member-#{id}-edit") |> render_click()
      refute has_element?(view, "#member-disable")

      view
      |> form("#member-form", member: %{reason: ""})
      |> render_submit(%{"action" => "enable"})

      assert has_element?(view, "#member-#{id}-status", "Active")
    end

    test "the last owner is protected", context do
      {:ok, view, _html} = live(context.owner_conn, ~p"/settings/members")

      view |> element("#member-#{context.owner.membership_id}-edit") |> render_click()
      # People never see a control to disable themselves.
      refute has_element?(view, "#member-disable")

      html =
        view
        |> form("#member-form", member: %{role: "admin"})
        |> render_submit(%{"action" => "role"})

      assert html =~ "at least one active owner"

      assert Accounts.get_organization_membership!(context.owner, context.owner.membership_id).role ==
               "owner"
    end

    test "members read the list without controls", context do
      {:ok, view, _html} = live(context.member_conn, ~p"/settings/members")

      assert has_element?(
               view,
               "#member-#{context.owner.membership_id}",
               context.owner.user.email
             )

      assert has_element?(view, "#members-read-only")
      refute has_element?(view, "#member-panel")
      refute has_element?(view, "[id$=-edit]")
    end
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
