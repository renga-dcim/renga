defmodule Renga.MembersTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Members

  setup do
    organization = organization_fixture()

    %{
      organization: organization,
      owner: member_scope(organization, "owner"),
      admin: member_scope(organization, "admin"),
      member: member_scope(organization, "member"),
      viewer: member_scope(organization, "viewer")
    }
  end

  defp membership(scope), do: Accounts.get_organization_membership!(scope, scope.membership_id)

  describe "listing" do
    test "lists every member with their user, including disabled ones", context do
      {:ok, _} = Members.disable_member(context.owner, context.viewer.membership_id)

      members = Members.list_members(context.member)
      assert length(members) == 4
      assert Enum.all?(members, &is_binary(&1.user.email))
      assert %{status: "disabled"} = Enum.find(members, &(&1.id == context.viewer.membership_id))
    end

    test "never lists another organization's members", context do
      other = organization_fixture()
      _stranger = member_scope(other, "owner")

      ids = context.owner |> Members.list_members() |> MapSet.new(& &1.organization_id)
      assert ids == MapSet.new([context.organization.id])
    end
  end

  describe "changing roles" do
    test "records the actor, before and after values, and the reason", context do
      assert {:ok, %{role: "viewer"}} =
               Members.change_role(context.admin, context.member.membership_id, "viewer",
                 reason: " Contractor offboarding "
               )

      assert [event] = Inventory.list_activity(context.owner, limit: 1)

      assert %{
               kind: "member_role_changed",
               field: "role",
               old_value: %{"value" => "member"},
               new_value: %{"value" => "viewer"},
               metadata: %{"reason" => "Contractor offboarding"}
             } = event

      assert event.actor_user_id == context.admin.user.id
      assert event.metadata["member"] == context.member.user.email
    end

    test "admins manage admins, members, and viewers but never owners", context do
      assert {:ok, _} = Members.change_role(context.admin, context.viewer.membership_id, "admin")

      assert {:error, :forbidden} =
               Members.change_role(context.admin, context.member.membership_id, "owner")

      assert {:error, :forbidden} =
               Members.change_role(context.admin, context.owner.membership_id, "admin")

      assert {:error, :forbidden} =
               Members.disable_member(context.admin, context.owner.membership_id)

      assert membership(context.owner).role == "owner"
    end

    test "owners may grant owner", context do
      assert {:ok, %{role: "owner"}} =
               Members.change_role(context.owner, context.admin.membership_id, "owner")
    end

    test "members and viewers cannot manage members", context do
      for scope <- [context.member, context.viewer] do
        assert {:error, :forbidden} =
                 Members.change_role(scope, context.viewer.membership_id, "member")

        assert {:error, :forbidden} = Members.disable_member(scope, context.viewer.membership_id)
        refute Members.can_manage?(scope)
        assert Members.grantable_roles(scope) == []
      end
    end

    test "re-reads the actor's role instead of trusting the scope", context do
      {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "member")

      assert {:error, :forbidden} =
               Members.change_role(context.admin, context.viewer.membership_id, "member")

      # A demoted owner keeps an owner scope but only an admin's ceiling.
      {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "owner")
      {:ok, _} = Members.change_role(context.admin, context.owner.membership_id, "admin")

      assert {:error, :forbidden} =
               Members.change_role(context.owner, context.viewer.membership_id, "owner")
    end

    test "rejects unknown roles and missing or foreign members", context do
      assert {:error, :invalid_role} =
               Members.change_role(context.owner, context.member.membership_id, "root")

      assert {:error, :not_found} =
               Members.change_role(context.owner, Ecto.UUID.generate(), "viewer")

      assert {:error, :not_found} = Members.change_role(context.owner, "not-a-uuid", "viewer")

      stranger = member_scope(organization_fixture(), "member")

      assert {:error, :not_found} =
               Members.change_role(context.owner, stranger.membership_id, "viewer")
    end

    test "a change to the same role records nothing", context do
      assert {:ok, _} = Members.change_role(context.owner, context.member.membership_id, "member")
      assert Inventory.list_activity(context.owner) == []
    end

    test "the grant picker follows the cached role", context do
      assert Members.grantable_roles(context.owner) == ~w(owner admin member viewer)
      assert Members.grantable_roles(context.admin) == ~w(admin member viewer)
    end
  end

  describe "the recovery owner" do
    test "the last active owner cannot be demoted or disabled", context do
      assert {:error, :last_owner} =
               Members.change_role(context.owner, context.owner.membership_id, "admin")

      {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "owner")
      admin_now_owner = context.admin

      assert {:ok, _} =
               Members.change_role(admin_now_owner, context.owner.membership_id, "admin")

      assert {:error, :last_owner} =
               Members.change_role(admin_now_owner, admin_now_owner.membership_id, "member")
    end

    test "a disabled owner does not count as a recovery owner", context do
      {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "owner")
      {:ok, _} = Members.disable_member(context.owner, context.admin.membership_id)

      assert {:error, :last_owner} =
               Members.change_role(context.owner, context.owner.membership_id, "admin")
    end
  end

  describe "disabling and enabling" do
    test "a disabled member cannot open the organization or act, and keeps their role", context do
      assert {:ok, %{status: "disabled", role: "member"}} =
               Members.disable_member(context.admin, context.member.membership_id,
                 reason: "Left the company"
               )

      assert Accounts.scope_for_user(context.member.user, context.organization.id).organization_id ==
               nil

      assert {:error, :forbidden} =
               Inventory.create_intake_api_key(context.member, %{name: "k"})

      assert {:ok, %{status: "active", role: "member"}} =
               Members.enable_member(context.admin, context.member.membership_id)

      kinds = context.owner |> Inventory.list_activity() |> Enum.map(& &1.kind)
      assert kinds == ["member_enabled", "member_disabled"]
    end

    test "people cannot disable themselves", context do
      assert {:error, :self} = Members.disable_member(context.admin, context.admin.membership_id)
    end
  end

  describe "invitations" do
    defp invite(scope, email, role) do
      Members.invite(
        scope,
        %{"email" => email, "role" => role},
        &"https://renga.test/invitations/#{&1}"
      )
    end

    defp token_from_email do
      assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
      [_, token] = Regex.run(~r{/invitations/(\S+)}, body)
      token
    end

    test "an invited person who confirmed the address joins with the role", context do
      user = user_fixture()

      assert {:ok, invitation} = invite(context.admin, String.upcase(user.email), "member")
      assert invitation.role == "member"
      token = token_from_email()

      assert Members.get_open_invitation(token).organization.id == context.organization.id
      assert {:ok, membership} = Members.accept_invitation(user, token)
      assert {membership.role, membership.status} == {"member", "active"}
      assert Accounts.scope_for_user(user, context.organization.id).membership_id == membership.id

      assert Members.list_invitations(context.admin) == []

      kinds = context.owner |> Inventory.list_activity() |> Enum.map(& &1.kind)
      assert kinds == ["member_joined", "member_invited"]

      # Single use.
      assert {:error, :invalid} = Members.accept_invitation(user, token)
      assert Members.get_open_invitation(token) == nil
    end

    test "only the invited, confirmed address may accept", context do
      invited = user_fixture()
      {:ok, _} = invite(context.owner, invited.email, "viewer")
      token = token_from_email()

      assert {:error, :wrong_email} = Members.accept_invitation(user_fixture(), token)

      unconfirmed = unconfirmed_user_fixture()
      {:ok, _} = invite(context.owner, unconfirmed.email, "viewer")
      unconfirmed_token = token_from_email()
      assert {:error, :wrong_email} = Members.accept_invitation(unconfirmed, unconfirmed_token)

      assert {:ok, _} = Members.accept_invitation(invited, token)
    end

    test "expired, revoked, and replaced invitations cannot be accepted", context do
      user = user_fixture()
      {:ok, first} = invite(context.owner, user.email, "viewer")
      first_token = token_from_email()

      # Inviting again replaces the open invitation.
      {:ok, second} = invite(context.owner, user.email, "member")
      second_token = token_from_email()
      assert [%{id: id}] = Members.list_invitations(context.owner)
      assert id == second.id
      assert {:error, :invalid} = Members.accept_invitation(user, first_token)
      refute first.id == second.id

      {:ok, _} = Members.revoke_invitation(context.owner, second.id)
      assert {:error, :invalid} = Members.accept_invitation(user, second_token)

      {:ok, third} = invite(context.owner, user.email, "member")
      third_token = token_from_email()

      Repo.update_all(
        from(i in Accounts.OrganizationInvitation, where: i.id == ^third.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, :invalid} = Members.accept_invitation(user, third_token)
      assert {:error, :invalid} = Members.accept_invitation(user, "made-up")
    end

    test "invitations follow the grant ceiling and members.manage", context do
      assert {:error, changeset} = invite(context.admin, "new@example.com", "owner")
      assert "is above what you may grant" in errors_on(changeset).role

      assert {:error, :forbidden} = invite(context.member, "new@example.com", "viewer")

      {:ok, owner_invite} = invite(context.owner, "boss@example.com", "owner")
      owner_token = token_from_email()
      assert {:error, :forbidden} = Members.revoke_invitation(context.admin, owner_invite.id)

      assert {:error, :forbidden} =
               invite(context.admin, "BOSS@example.com", "viewer")

      refute_received {:email, %{subject: "You're invited" <> _}}
      assert [%{id: id, role: "owner"}] = Members.list_invitations(context.owner)
      assert id == owner_invite.id

      boss = user_fixture(%{email: "boss@example.com"})
      assert {:ok, %{role: "owner"}} = Members.accept_invitation(boss, owner_token)
    end

    test "an invitation dies with its inviter's authority", context do
      user = user_fixture()
      {:ok, _} = invite(context.admin, user.email, "admin")
      token = token_from_email()

      {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "member")
      assert {:error, :forbidden} = Members.accept_invitation(user, token)
    end

    test "rejects addresses that already belong to a member", context do
      assert {:error, changeset} = invite(context.owner, context.member.user.email, "admin")
      assert "already belongs to a member" in errors_on(changeset).email
      refute_received {:email, %{subject: "You're invited" <> _}}
    end

    test "acceptance re-reads the recipient's confirmed email", context do
      user = user_fixture()
      {:ok, invitation} = invite(context.owner, user.email, "viewer")
      token = token_from_email()

      user
      |> Ecto.Changeset.change(email: "changed@example.com")
      |> Repo.update!()

      assert {:error, :wrong_email} = Members.accept_invitation(user, token)
      assert Accounts.get_user_organization_membership(user, context.organization.id) == nil
      assert Members.get_open_invitation(token).id == invitation.id
    end

    test "acceptance refuses inactive organizations and existing disabled members", context do
      inactive_user = user_fixture()
      {:ok, _} = invite(context.owner, inactive_user.email, "viewer")
      inactive_token = token_from_email()

      Repo.update_all(
        from(o in Accounts.Organization, where: o.id == ^context.organization.id),
        set: [status: "disabled"]
      )

      assert {:error, :forbidden} = Members.accept_invitation(inactive_user, inactive_token)

      other_organization = organization_fixture()
      other_owner = member_scope(other_organization, "owner")
      existing_user = user_fixture()
      {:ok, _} = invite(other_owner, existing_user.email, "viewer")
      existing_token = token_from_email()
      membership = organization_membership_fixture(existing_user, other_organization)

      Repo.update_all(
        from(m in Accounts.OrganizationMembership, where: m.id == ^membership.id),
        set: [status: "disabled"]
      )

      assert {:error, :already_member} =
               Members.accept_invitation(existing_user, existing_token)
    end
  end
end
