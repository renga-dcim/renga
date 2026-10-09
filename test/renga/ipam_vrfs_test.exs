defmodule Renga.IPAMVrfsTest do
  @moduledoc """
  VRFs (RFD 4, Phase 2): routing namespaces with resource envelopes, written
  by owners and admins only, unique per organization regardless of case,
  and never deleted out from under their prefixes.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Prefix
  alias Renga.Inventory.Resource
  alias Renga.IPAM
  alias Renga.IPAM.Vrf

  setup do
    organization = organization_fixture()
    %{organization: organization, admin: scope_for(organization, "admin")}
  end

  test "owners and admins create a VRF with its envelope and an Activity event", context do
    assert {:ok, %Vrf{} = vrf} =
             IPAM.create_vrf(context.admin, %{
               name: " Blue ",
               route_distinguisher: "65000:1",
               description: "Tenant"
             })

    assert %{name: "Blue", route_distinguisher: "65000:1", status: "active"} = vrf
    assert vrf.resource.kind == "vrf"
    assert vrf.resource.display_name == "Blue"
    assert "vrf-" <> _uuid = vrf.resource.name

    assert [event] =
             context.admin
             |> Inventory.list_activity()
             |> Enum.filter(&(&1.resource_id == vrf.resource_id))

    assert %{kind: "created", field: "vrf", new_value: %{"value" => "Blue"}} = event
    assert event.actor_user_id == context.admin.user.id
    assert RengaWeb.ChangeDescription.describe(event) == "Created VRF Blue"

    assert {:ok, _} = IPAM.create_vrf(scope_for(context.organization, "owner"), %{name: "Red"})

    assert Enum.map(IPAM.list_routing_tables(context.admin), &(&1 && &1.name)) == [
             nil,
             "Blue",
             "Red"
           ]
  end

  test "members, viewers, and revoked admins cannot write VRFs", context do
    vrf = vrf_fixture(context.admin, "blue")

    for role <- ~w(member viewer) do
      scope = scope_for(context.organization, role)
      assert {:error, :forbidden} = IPAM.create_vrf(scope, %{name: "red"})
      assert {:error, :forbidden} = IPAM.update_vrf(scope, vrf, %{name: "green"})
      assert {:error, :forbidden} = IPAM.delete_vrf(scope, vrf)
    end

    revoked = scope_for(context.organization, "admin")
    membership = Repo.get!(Accounts.OrganizationMembership, revoked.membership_id)
    {:ok, _} = Accounts.update_organization_membership(membership, %{status: "disabled"})
    assert {:error, :forbidden} = IPAM.create_vrf(revoked, %{name: "red"})

    assert [%{name: "blue"}] = IPAM.list_vrfs(context.admin)
  end

  test "names are unique regardless of case, and default is reserved", context do
    {:ok, _} = IPAM.create_vrf(context.admin, %{name: "Blue", route_distinguisher: "65000:1"})

    assert {:error, changeset} = IPAM.create_vrf(context.admin, %{name: "BLUE"})
    assert %{name: ["is already a VRF in this organization"]} = errors_on(changeset)

    assert {:error, changeset} =
             IPAM.create_vrf(context.admin, %{name: "Red", route_distinguisher: "65000:1"})

    assert %{route_distinguisher: ["is already used by another VRF"]} = errors_on(changeset)

    assert {:error, changeset} = IPAM.create_vrf(context.admin, %{name: " Default "})
    assert %{name: ["is reserved for the global routing table"]} = errors_on(changeset)

    assert {:error, changeset} = IPAM.create_vrf(context.admin, %{name: "Red", status: "gone"})
    assert %{status: ["is invalid"]} = errors_on(changeset)

    # A VRF literally called Global is allowed: its events keep its id.
    assert {:ok, _} = IPAM.create_vrf(context.admin, %{name: "Global"})

    # Another organization has its own names, and a rejected VRF leaves no
    # envelope behind.
    assert {:ok, _} = IPAM.create_vrf(scope_for(organization_fixture(), "admin"), %{name: "Blue"})
    assert vrf_resources(context.organization) == 2
  end

  test "VRF envelopes are created only through the IPAM context", context do
    assert {:error, changeset} =
             Inventory.create_resource(context.admin, %{kind: "vrf", name: "loose"})

    assert %{kind: ["must be created through the IPAM context"]} = errors_on(changeset)
  end

  test "a rename relabels the VRF and its prefixes and records each change", context do
    vrf = vrf_fixture(context.admin, "blue")
    prefix = prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})
    global = prefix_fixture(context.admin, "10.0.0.0/24")
    assert prefix.resource.display_name == "10.0.0.0/24 (blue)"

    assert {:ok, updated} =
             IPAM.update_vrf(context.admin, vrf, %{name: "Tenant", status: "deprecated"})

    assert updated.resource.display_name == "Tenant"
    assert Repo.get!(Resource, prefix.resource_id).display_name == "10.0.0.0/24 (Tenant)"
    assert Repo.get!(Resource, global.resource_id).display_name == "10.0.0.0/24"

    events =
      context.admin
      |> Inventory.list_activity()
      |> Enum.filter(&(&1.resource_id == vrf.resource_id and &1.kind == "updated"))
      |> Map.new(&{&1.field, {&1.old_value["value"], &1.new_value["value"]}})

    assert events == %{"name" => {"blue", "Tenant"}, "status" => {"active", "deprecated"}}

    # The prefix list resolves the renamed table by name, ignoring case.
    assert %{id: id} = IPAM.get_vrf_by_name(context.admin, " tenant ")
    assert id == vrf.id
  end

  test "clearing optional fields is audited and clearing the name is invalid", context do
    for empty <- ["", nil] do
      vrf =
        vrf_fixture(context.admin, "clear-#{System.unique_integer([:positive])}", %{
          route_distinguisher: "65000:1"
        })

      assert {:ok, cleared} = IPAM.update_vrf(context.admin, vrf, %{route_distinguisher: empty})
      assert cleared.route_distinguisher == nil

      assert Enum.any?(Inventory.list_activity(context.admin), fn event ->
               event.resource_id == vrf.resource_id and event.field == "route_distinguisher" and
                 event.old_value == %{"value" => "65000:1"} and
                 event.new_value == %{"value" => nil}
             end)

      assert {:error, changeset} = IPAM.update_vrf(context.admin, cleared, %{name: empty})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert IPAM.get_vrf!(context.admin, vrf.id).name == vrf.name
    end
  end

  test "stale VRF edits cannot overwrite current intent or write events", context do
    vrf = vrf_fixture(context.admin, "blue")
    {:ok, updated} = IPAM.update_vrf(context.admin, vrf, %{description: "Tenant"})
    events = Inventory.list_activity(context.admin)

    assert {:error, :stale} = IPAM.update_vrf(context.admin, vrf, %{name: "red"})
    assert %{name: "blue", description: "Tenant"} = Repo.get!(Vrf, vrf.id)
    assert Inventory.list_activity(context.admin) == events

    assert {:ok, %{name: "red"}} = IPAM.update_vrf(context.admin, updated, %{name: "red"})
  end

  test "counts prefixes per routing table", context do
    blue = vrf_fixture(context.admin, "blue")
    vrf_fixture(context.admin, "empty")
    prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})
    prefix_fixture(context.admin, "10.0.1.0/24", %{vrf: "blue"})
    prefix_fixture(context.admin, "10.0.0.0/24")
    prefix_fixture(scope_for(organization_fixture(), "admin"), "10.0.0.0/24")

    assert IPAM.prefix_counts(context.admin) == %{nil => 1, blue.id => 2}
  end

  test "a VRF holding prefixes cannot be deleted; an empty one can", context do
    vrf = vrf_fixture(context.admin, "blue")
    prefix = prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})

    assert {:error, :in_use} = IPAM.delete_vrf(context.admin, vrf)
    assert Repo.get!(Vrf, vrf.id)

    {:ok, _} = IPAM.delete_prefix(context.admin, prefix)
    assert {:ok, _} = IPAM.delete_vrf(context.admin, vrf)

    refute Repo.get(Vrf, vrf.id)
    refute Repo.get(Resource, vrf.resource_id)

    event =
      context.admin
      |> Inventory.list_activity()
      |> Enum.find(&(&1.field == "vrf" and &1.kind == "deleted"))

    assert %{resource_id: nil, old_value: %{"value" => "blue"}} = event
    assert RengaWeb.ChangeDescription.describe(event) == "Deleted VRF blue"
  end

  test "prefixes belong to one routing table of their own organization", context do
    blue = vrf_fixture(context.admin, "blue")
    other = scope_for(organization_fixture(), "admin")
    foreign = vrf_fixture(other, "blue")

    # Another organization's VRF is not a table here.
    assert {:error, changeset} =
             IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24", vrf_id: foreign.id})

    assert %{vrf_id: ["does not exist"]} = errors_on(changeset)

    assert_raise Ecto.NoResultsError, fn -> IPAM.get_vrf!(context.admin, foreign.id) end
    assert IPAM.get_vrf_by_name(context.admin, "BLUE").id == blue.id

    {:ok, prefix} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24", vrf_id: blue.id})

    assert {:error, changeset} =
             IPAM.update_prefix(context.admin, prefix, %{vrf_id: foreign.id})

    assert %{vrf_id: ["does not exist"]} = errors_on(changeset)
    assert Repo.get!(Prefix, prefix.id).vrf_id == blue.id
    assert IPAM.list_prefix_rows(other, blue.id) == %{ipv4: [], ipv6: []}
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp vrf_resources(organization) do
    Resource
    |> where([resource], resource.organization_id == ^organization.id)
    |> where([resource], resource.kind == "vrf")
    |> Repo.aggregate(:count)
  end
end
