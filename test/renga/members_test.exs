defmodule Renga.MembersTest do
  use Renga.DataCase, async: true

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
end
