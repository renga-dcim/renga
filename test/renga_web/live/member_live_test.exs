defmodule RengaWeb.MemberLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Members

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

  describe "invitations" do
    test "admins invite, see, and revoke pending invitations", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")

      refute has_element?(view, "#invite-form option[value=owner]")

      view
      |> form("#invite-form", invitation: %{email: "not-an-email", role: "member"})
      |> render_submit()

      assert has_element?(view, "#invite-form", "must have the @ sign")

      view
      |> form("#invite-form", invitation: %{email: "new@example.com", role: "viewer"})
      |> render_submit()

      assert_received {:email, %{to: [{_, "new@example.com"}], text_body: body}}
      assert body =~ "/invitations/"

      [invitation] = Members.list_invitations(context.admin)
      assert has_element?(view, "#invitation-#{invitation.id}", "new@example.com")

      view |> element("#invitation-#{invitation.id}-revoke") |> render_click()
      refute has_element?(view, "#invitation-#{invitation.id}")
      assert Members.list_invitations(context.admin) == []
    end

    test "the invited person accepts and can open the organization", context do
      user = user_fixture()

      {:ok, _} =
        Members.invite(context.owner, %{"email" => user.email, "role" => "member"}, &"/i/#{&1}")

      assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
      [_, token] = Regex.run(~r{/i/(\S+)}, body)

      conn = log_in_user(build_conn(), user)
      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")
      assert has_element?(view, "#invitation-offer", "member")

      assert {:error, {:live_redirect, %{to: "/organizations"}}} =
               view |> element("#accept-invitation") |> render_click()

      assert Accounts.scope_for_user(user, context.owner.organization_id).roles == ["member"]

      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")
      assert has_element?(view, "#invitation-invalid")
    end

    test "someone else's account is refused", context do
      {:ok, _} =
        Members.invite(
          context.owner,
          %{"email" => "a@example.com", "role" => "member"},
          &"/i/#{&1}"
        )

      assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
      [_, token] = Regex.run(~r{/i/(\S+)}, body)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), user_fixture()), ~p"/invitations/#{token}")

      html = view |> element("#accept-invitation") |> render_click()
      assert html =~ "for a different email address"
    end

    test "signing in comes first", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/invitations/anything")
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
