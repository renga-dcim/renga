defmodule RengaWeb.MemberLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.ScimFixtures

  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.UserIdentity
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Members
  alias Renga.Repo
  alias Renga.Roles
  alias Renga.Scim.Client
  alias Renga.Scim.Linking
  alias Renga.Scim.Users

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

  describe "assignments" do
    test "admins give a member a further role and take it away", context do
      {:ok, network} =
        Roles.create_role(context.owner, %{
          "name" => "Network",
          "permissions" => ["ipam.edit"]
        })

      {:ok, exporter} =
        Roles.create_role(context.owner, %{
          "name" => "Exporter",
          "permissions" => ["organization.export"]
        })

      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")
      id = context.member.membership_id

      view |> element("#member-#{id}-roles") |> render_click()
      assert has_element?(view, "#assign-current", "No further roles")

      # Only roles within an admin's ceiling are offered.
      assert has_element?(view, "#assign-form option[value='#{network.id}']")
      refute has_element?(view, "#assign-form option[value='#{exporter.id}']")
      refute has_element?(view, "#assign-form option[value=owner]")

      view
      |> form("#assign-form",
        assignment: %{role: network.id, valid_until: "2999-01-01T09:00", reason: "On call"}
      )
      |> render_submit()

      [assignment] = Assignments.list_assignments(context.admin)
      assert has_element?(view, "#assignment-#{assignment.id}", "Until 2999-01-01 09:00 UTC")
      assert has_element?(view, "#member-#{id}-assignment-#{assignment.id}", "Network")

      view |> form("#assign-form", assignment: %{role: network.id}) |> render_submit()
      assert render(view) =~ "They already hold that role."

      view |> element("#assignment-#{assignment.id}-remove") |> render_click()
      refute has_element?(view, "#assignment-#{assignment.id}")
      assert Assignments.list_assignments(context.admin) == []
    end

    test "members see further roles but cannot change them", context do
      {:ok, _} =
        Assignments.assign(context.admin, context.member.membership_id, %{
          "role" => "viewer"
        })

      {:ok, view, _html} = live(context.member_conn, ~p"/settings/members")
      assert has_element?(view, "#member-list", "+ viewer")
      refute has_element?(view, "#assign-panel")
    end

    test "connected pages refresh roles, authority, expiry, and disabled membership", context do
      {:ok, admin_view, _html} = live(context.admin_conn, ~p"/settings/members")
      admin_view |> element("#member-#{context.member.membership_id}-roles") |> render_click()

      {:ok, network} =
        Roles.create_role(context.owner, %{
          "name" => "Network live",
          "permissions" => ["ipam.edit"]
        })

      send(admin_view.pid, {:inventory_changed, context.owner.organization_id})

      assert eventually(fn ->
               has_element?(admin_view, "#assign-form option[value='#{network.id}']")
             end)

      {:ok, _deleted} = Roles.delete_role(context.owner, network)
      send(admin_view.pid, {:inventory_changed, context.owner.organization_id})

      assert eventually(fn ->
               not has_element?(admin_view, "#assign-form option[value='#{network.id}']")
             end)

      {:ok, member_view, _html} = live(context.member_conn, ~p"/settings/members")
      refute has_element?(member_view, "#invite-member")

      expires_at = DateTime.add(Renga.Time.utc_now_ms(), 500, :millisecond)

      {:ok, _assignment} =
        Assignments.assign(context.owner, context.member.membership_id, %{
          "role" => "admin",
          "valid_until" => expires_at
        })

      send(member_view.pid, {:inventory_changed, context.owner.organization_id})
      assert eventually(fn -> has_element?(member_view, "#invite-member") end)
      Process.sleep(700)

      assert eventually(fn ->
               not has_element?(member_view, "#invite-member") and
                 has_element?(member_view, "#members-read-only")
             end)

      assert {:ok, _disabled} =
               Members.disable_member(context.owner, context.member.membership_id)

      assert {"/organizations", _flash} =
               send_and_assert_redirect(
                 member_view,
                 {:inventory_changed, context.owner.organization_id}
               )
    end

    test "management controls honor the target's assigned access ceiling", context do
      {:ok, owner_only} =
        Roles.create_role(context.owner, %{
          "name" => "Owner operations",
          "permissions" => ["organization.manage"]
        })

      {:ok, _assignment} =
        Assignments.assign(context.owner, context.member.membership_id, %{"role" => owner_only.id})

      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")
      refute has_element?(view, "#member-#{context.member.membership_id}-edit")
      assert has_element?(view, "#member-#{context.member.membership_id}-roles")
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

    test "names the deployment token on an operator invitation", context do
      organization = Repo.get!(Accounts.Organization, context.owner.organization_id)

      {:ok, {token, _plaintext}} =
        Renga.Operators.create_token(
          %{name: "cloud", scopes: ["organizations:write"]},
          Renga.DeploymentAudit.operator("test")
        )

      {:ok, invitation} =
        Renga.Operators.Organizations.invite_owner(
          organization.id,
          "operator-invited@example.com",
          Renga.DeploymentAudit.token(token, Ecto.UUID.generate()),
          &"/invitations/#{&1}"
        )

      {:ok, view, _html} = live(context.owner_conn, ~p"/settings/members")

      assert has_element?(
               view,
               "#invitation-#{invitation.id}",
               "Invited by the deployment (token: cloud)"
             )
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

  describe "SCIM directory" do
    setup context do
      connection = scim_connection_fixture(context.owner, %{"default_role" => "member"})
      {token, _value} = scim_token_fixture(context.owner, connection)
      %{connection: connection, client: %Client{connection: connection, token_id: token.id}}
    end

    test "managers see entries, linked or not, and SCIM members are left to the provider",
         context do
      {:ok, unlinked} =
        Users.create(context.client, %{"userName" => "pending@example.com", "externalId" => "p"})

      {:ok, linked} =
        Users.create(context.client, %{
          "userName" => "linked@example.com",
          "externalId" => "sub-l",
          "displayName" => "Linked Person"
        })

      user = user_fixture()

      identity =
        Repo.insert!(%UserIdentity{
          user_id: user.id,
          provider_id: context.connection.provider_id,
          subject: "sub-l"
        })

      Linking.link_identity(identity, %{"sub" => "sub-l"})
      granted = Repo.get_by!(OrganizationMembership, user_id: user.id)

      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")

      assert has_element?(view, "#directory-#{linked.id}", "Linked Person")
      assert has_element?(view, "#directory-#{linked.id}-account", user.email)
      assert has_element?(view, "#directory-#{unlinked.id}-unlinked", "Not signed in yet")
      assert has_element?(view, "#member-#{granted.id}-scim", "Managed by SCIM")
      refute has_element?(view, "#member-#{granted.id}-edit")

      # A push arrives while the page is open.
      {:ok, _entry} =
        Users.patch(context.client, unlinked.id, [
          %{"op" => "replace", "path" => "active", "value" => false}
        ])

      assert has_element?(view, "#directory-#{unlinked.id}-status", "Inactive")
    end

    test "an entry linked to an account without a global email still names it", context do
      {:ok, entry} =
        Users.create(context.client, %{
          "userName" => "nomail@example.com",
          "externalId" => "sub-n"
        })

      # An organization provider's sign-up leaves the global email unset (RFD 15).
      user = Repo.insert!(%Renga.Accounts.User{})

      identity =
        Repo.insert!(%UserIdentity{
          user_id: user.id,
          provider_id: context.connection.provider_id,
          subject: "sub-n"
        })

      Linking.link_identity(identity, %{"sub" => "sub-n"})

      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/members")

      assert has_element?(view, "#directory-#{entry.id}-account", "Account without an email")
    end

    test "members without members.manage do not see the directory", context do
      {:ok, _entry} = Users.create(context.client, %{"userName" => "x", "externalId" => "x"})

      {:ok, view, _html} = live(context.member_conn, ~p"/settings/members")
      refute has_element?(view, "#directory")
    end
  end

  describe "imported people" do
    @describetag :tmp_dir

    # The source had Ada, an active admin, and Bo, a disabled member; it is
    # exported, removed, and imported into a target with its own owner.
    setup %{tmp_dir: tmp_dir} do
      source = organization_fixture()
      {_conn, source_owner} = member(source, "owner")
      {_conn, ada} = member(source, "admin")
      {_conn, bo} = member(source, "member")
      {:ok, _bo} = Members.disable_member(source_owner, bo.membership_id)

      path = Path.join(tmp_dir, "source.tar.zst")
      {:ok, _summary} = Renga.Transfers.Export.write(source, path, parts: [])
      Renga.Repo.delete!(source)

      target = organization_fixture()
      {target_conn, target_owner} = member(target, "owner")

      {:ok, _import} =
        Renga.Transfers.Import.run(target, path,
          imported_by_user_id: target_owner.user.id,
          operator: "ops@example.com",
          tmp_dir: tmp_dir
        )

      {member_conn, _member} = member(target, "member")

      %{ada: ada, bo: bo, target_conn: target_conn, target_member_conn: member_conn}
    end

    test "owners invite back the people who were active members", context do
      {:ok, view, _html} = live(context.target_conn, ~p"/settings/members")

      assert has_element?(view, "#imported-people", context.ada.user.email)
      refute has_element?(view, "#imported-people", context.bo.user.email)

      principal =
        Renga.Repo.get_by!(Renga.Transfers.ImportedPrincipal, source_id: context.ada.user.id)

      row = "#imported-#{principal.id}"
      assert has_element?(view, row, "admin")
      assert has_element?(view, row, "Not sent")

      view |> element("#{row}-invite") |> render_click()

      assert_received {:email, %{to: [{_, email}], subject: "You're invited" <> _}}
      assert email == context.ada.user.email
      assert has_element?(view, row, "Sent")
      assert has_element?(view, "#{row}-invite", "Send again")
    end

    test "malformed held membership metadata cannot break the members page", context do
      principal =
        Renga.Repo.get_by!(Renga.Transfers.ImportedPrincipal, source_id: context.ada.user.id)

      for metadata <- [42, "unexpected", [%{}]] do
        Renga.Repo.query!(
          """
          UPDATE imported_held_records SET record = jsonb_set(record, '{metadata}', $2::jsonb)
          WHERE principal_id = $1 AND record_type = 'organization_memberships'
          """,
          [Ecto.UUID.dump!(principal.id), metadata]
        )

        {:ok, view, _html} = live(context.target_conn, ~p"/settings/members")
        assert has_element?(view, "#members")
        refute has_element?(view, "#imported-#{principal.id}-invite")
      end
    end

    test "members do not see imported people", context do
      {:ok, view, _html} = live(context.target_member_conn, ~p"/settings/members")
      refute has_element?(view, "#imported-people")
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

  defp eventually(check, attempts \\ 20)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(25)
      eventually(check, attempts - 1)
    end
  end
end
