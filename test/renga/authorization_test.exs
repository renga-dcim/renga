defmodule Renga.AuthorizationTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts
  alias Renga.Accounts.SessionMFA
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Repo
  alias Renga.SecuritySettings

  # RFD 17's built-in role table, written out so a catalogue change has to
  # change this test too.
  @expected %{
    "owner" => ~w(inventory.read inventory.reconcile findings.act catalog.author
                  inventory.edit requests.decide catalog.expectations dcim.edit ipam.edit
                  topology.edit jobs.request views.share teams.manage groups.manage triage_rules.manage
                  intake_keys.manage members.manage roles.manage organization.manage
                  organization.export scim.manage),
    "admin" => ~w(inventory.read inventory.reconcile findings.act catalog.author
                  inventory.edit requests.decide catalog.expectations dcim.edit ipam.edit
                  topology.edit jobs.request views.share teams.manage groups.manage triage_rules.manage
                  intake_keys.manage members.manage roles.manage),
    "member" => ~w(inventory.read inventory.reconcile findings.act catalog.author
                   requests.create),
    "viewer" => ~w(inventory.read)
  }

  describe "catalogue" do
    test "built-in roles grant exactly RFD 17's table" do
      for role <- Authorization.built_in_roles() do
        assert Enum.sort(Authorization.role_permissions(role)) == Enum.sort(@expected[role]),
               "#{role} permissions drifted"
      end
    end

    test "every built-in permission is in the catalogue and every other entry is explicit" do
      granted = @expected |> Map.values() |> List.flatten() |> Enum.uniq()

      assert Enum.sort(granted ++ Authorization.explicit_permissions()) ==
               Enum.sort(Authorization.permissions())
    end

    test "nobody holds an explicit permission by default, but owners and admins may issue them" do
      assert Authorization.explicit_permissions() == ~w(queries.run queries.run_sensitive)

      for permission <- Authorization.explicit_permissions() do
        assert Authorization.explicit?(permission)
        assert Authorization.roles_granting(permission) == []
        assert permission in Authorization.custom_role_permissions()
        assert permission in Authorization.grantable_permissions("owner")
        assert permission in Authorization.grantable_permissions("admin")
        refute permission in Authorization.grantable_permissions("member")
      end

      refute Authorization.explicit?("jobs.request")
    end

    test "roles_granting lists roles most privileged first" do
      assert Authorization.roles_granting("dcim.edit") == ~w(owner admin)
      assert Authorization.roles_granting("requests.create") == ~w(member)
      assert Authorization.roles_granting("inventory.read") == ~w(owner admin member viewer)
    end

    test "grant ceilings keep owner with owners" do
      assert Authorization.grantable_roles("owner") == ~w(owner admin member viewer)
      assert Authorization.grantable_roles("admin") == ~w(admin member viewer)
      assert Authorization.grantable_roles("member") == []
      assert Authorization.grantable_roles("viewer") == []
    end

    test "every permission is described" do
      for permission <- Authorization.permissions(),
          do: assert(Authorization.describe(permission) =~ ~r/^[A-Z]/)
    end

    test "an unknown permission is a programming error" do
      assert_raise ArgumentError, ~r/unknown permission/, fn ->
        Authorization.roles_granting("inventory.delete")
      end

      assert_raise ArgumentError, fn -> Authorization.allowed?(nil, "nope") end
    end
  end

  describe "allowed?/3" do
    setup do
      %{organization: organization_fixture()}
    end

    test "follows the scope's cached role for people", %{organization: organization} do
      for role <- Authorization.built_in_roles(), permission <- Authorization.permissions() do
        scope = %Scope{user: %{id: "u"}, organization_id: organization.id, roles: [role]}

        assert Authorization.allowed?(scope, permission) == permission in @expected[role],
               "#{role} / #{permission}"
      end
    end

    test "never allows machine scopes or no scope", %{organization: organization} do
      for principal <- Authorization.machine_principals() do
        scope = %Scope{organization_id: organization.id, roles: [principal]}
        refute Authorization.allowed?(scope, "inventory.reconcile")
      end

      refute Authorization.allowed?(nil, "inventory.read")
    end
  end

  describe "authorize!/3" do
    setup do
      %{organization: organization_fixture()}
    end

    test "re-reads the membership's role in the database", %{organization: organization} do
      for role <- Authorization.built_in_roles() do
        scope = member_scope(organization, role)

        for permission <- Authorization.permissions() do
          expected = if permission in @expected[role], do: {:ok, :ok}, else: {:error, :forbidden}

          assert Repo.transaction(fn -> Authorization.authorize!(scope, permission) end) ==
                   expected,
                 "#{role} / #{permission}"
        end
      end
    end

    test "ignores a stale role cached in the scope", %{organization: organization} do
      scope = member_scope(organization, "viewer")
      stale = %{scope | roles: ["owner"]}

      assert Authorization.allowed?(stale, "dcim.edit")

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.authorize!(stale, "dcim.edit") end)
    end

    test "refuses disabled memberships and inactive organizations", %{organization: organization} do
      scope = member_scope(organization, "owner")

      Repo.update_all(
        from(m in Accounts.OrganizationMembership, where: m.id == ^scope.membership_id),
        set: [status: "disabled"]
      )

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.authorize!(scope, "inventory.read") end)

      other = organization_fixture()
      owner = member_scope(other, "owner")

      Repo.update_all(
        from(o in Accounts.Organization, where: o.id == ^other.id),
        set: [status: "disabled"]
      )

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.authorize!(owner, "inventory.read") end)
    end

    test "can take shared locks", %{organization: organization} do
      scope = member_scope(organization, "admin")

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Authorization.authorize!(scope, "jobs.request", lock: :share)
               end)

      assert {:error, :forbidden} =
               Repo.transaction(fn ->
                 Authorization.authorize!(scope, "organization.manage", lock: :share)
               end)
    end

    test "refuses a stale human scope after MFA becomes required", %{
      organization: organization
    } do
      scope = member_scope(organization, "owner")

      assert {:ok, true} =
               SecuritySettings.put(scope, :require_mfa, true, "Organization policy")

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.authorize!(scope, "inventory.read") end)

      satisfied = %{scope | user: %{scope.user | session_mfa: SessionMFA.for_method(:passkey)}}

      assert {:ok, :ok} =
               Repo.transaction(fn -> Authorization.authorize!(satisfied, "inventory.read") end)
    end

    test "refuses machine scopes", %{organization: organization} do
      scope = %Scope{organization_id: organization.id, roles: ["topology_reconciler"]}

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Authorization.authorize!(scope, "inventory.reconcile") end)
    end
  end

  describe "authorize_system!/2" do
    setup do
      %{organization: organization_fixture()}
    end

    test "admits only the named principal", %{organization: organization} do
      scope = %Scope{organization_id: organization.id, roles: ["topology_reconciler"]}

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Authorization.authorize_system!(scope, "topology_reconciler")
               end)

      assert {:error, :forbidden} =
               Repo.transaction(fn ->
                 Authorization.authorize_system!(scope, "catalog_reconciler")
               end)
    end

    test "never admits a person, whatever their scope claims", %{organization: organization} do
      owner = member_scope(organization, "owner")
      claimed = %{owner | roles: ["topology_reconciler"]}

      assert {:error, :forbidden} =
               Repo.transaction(fn ->
                 Authorization.authorize_system!(claimed, "topology_reconciler")
               end)
    end

    test "rejects principals that do not exist" do
      assert_raise FunctionClauseError, fn ->
        Authorization.authorize_system!(%Scope{}, "root")
      end
    end
  end
end
