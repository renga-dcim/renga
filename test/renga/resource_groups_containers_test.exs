defmodule Renga.ResourceGroupsContainersTest do
  @moduledoc """
  Container membership (RFD 18): a site, location, or rack in a group passes
  the group to everything placed or contained in it. The inventory view
  follows current placement; the trusted view follows only placement and
  containment people set or confirmed.
  """
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.ResourceGroups
  alias Renga.ResourceGroups.Membership

  setup do
    organization = organization_fixture()
    admin = member_scope(organization, "admin")

    {:ok, site} =
      DCIM.create_site(admin, %{name: "DC-A"}, %{slug: "dc-a", status: "active"})

    {:ok, cage} =
      DCIM.create_location(admin, %{name: "Cage 7"}, %{site_id: site.id, status: "active"})

    {:ok, rack} =
      DCIM.create_rack(admin, %{name: "R12"}, %{
        site_id: site.id,
        location_id: cage.id,
        height_units: 42,
        status: "active"
      })

    {:ok, web} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})
    {:ok, acme} = ResourceGroups.create_group(admin, %{name: "Acme"})

    %{
      organization: organization,
      admin: admin,
      site: site,
      cage: cage,
      rack: rack,
      web: web,
      acme: acme
    }
  end

  test "a confirmed placement inherits the rack's group in both views", context do
    place!(context, confirmed: true)
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.acme, [context.rack.resource_id])

    assert views(context.web, context.acme) == ~w(inventory trusted)

    assert [%{direct: false, trusted: true, via: [%{name: "R12", kind: "rack", trusted: true}]}] =
             ResourceGroups.list_resource_groups(context.admin, context.web.id)
  end

  test "an unconfirmed placement inherits only in the inventory view", context do
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.acme, [context.rack.resource_id])
    place!(context, confirmed: false)

    assert views(context.web, context.acme) == ~w(inventory)

    assert [%{trusted: false, via: [%{name: "R12", trusted: false}]}] =
             ResourceGroups.list_resource_groups(context.admin, context.web.id)

    # Confirming the placement makes the path trusted.
    place!(context, confirmed: true)
    assert views(context.web, context.acme) == ~w(inventory trusted)
  end

  test "a site's group reaches its locations, racks, and what is racked", context do
    place!(context, confirmed: true)
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.acme, [context.site.resource_id])

    for resource_id <- [context.cage.resource_id, context.rack.resource_id, context.web.id] do
      assert views(resource_id, context.acme) == ~w(inventory trusted)
    end

    assert [%{via: [%{name: "DC-A", kind: "site"}]}] =
             ResourceGroups.list_resource_groups(context.admin, context.web.id)
  end

  test "leaving the container leaves the group", context do
    place!(context, confirmed: true)
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.acme, [context.cage.resource_id])
    assert views(context.web, context.acme) == ~w(inventory trusted)

    {:ok, _removed} = DCIM.remove_current_placement(context.admin, context.web.id)
    assert views(context.web, context.acme) == []
  end

  test "removing one path keeps an independent direct or inherited path", context do
    place!(context, confirmed: true)

    {:ok, 3} =
      ResourceGroups.add_members(context.admin, context.acme, [
        context.web.id,
        context.rack.resource_id,
        context.site.resource_id
      ])

    {:ok, 1} =
      ResourceGroups.remove_members(context.admin, context.acme, [context.rack.resource_id])

    assert [%{direct: true, via: [%{name: "DC-A"}]}] =
             ResourceGroups.list_resource_groups(context.admin, context.web.id)

    {:ok, 1} = ResourceGroups.remove_members(context.admin, context.acme, [context.web.id])
    assert views(context.web, context.acme) == ~w(inventory trusted)

    {:ok, 1} =
      ResourceGroups.remove_members(context.admin, context.acme, [context.site.resource_id])

    assert views(context.web, context.acme) == []
  end

  test "moving a location moves what it holds between groups", context do
    place!(context, confirmed: true)

    {:ok, hall} =
      DCIM.create_location(context.admin, %{name: "Hall B"}, %{
        site_id: context.site.id,
        status: "active"
      })

    {:ok, 1} = ResourceGroups.add_members(context.admin, context.acme, [hall.resource_id])
    assert views(context.web, context.acme) == []

    {:ok, _cage} = DCIM.update_location(context.admin, context.cage, %{parent_id: hall.id})
    assert views(context.web, context.acme) == ~w(inventory trusted)
  end

  describe "reconciliation" do
    setup context do
      {:ok, source} = Inventory.create_source(context.admin, %{kind: "manual", name: "import"})

      reconciler = %Renga.Accounts.Scope{
        organization: context.organization,
        organization_id: context.organization.id,
        roles: ["placement_reconciler"]
      }

      {:ok, 1} =
        ResourceGroups.add_members(context.admin, context.acme, [context.rack.resource_id])

      %{source: source, reconciler: reconciler}
    end

    test "observed placement into a grouped rack grants only the inventory view", context do
      observe!(context)

      assert {:ok, placement} =
               DCIM.reconcile_placement_evidence(context.reconciler, context.web.id)

      refute placement.confirmed
      assert views(context.web, context.acme) == ~w(inventory)
    end

    test "agreeing evidence keeps a confirmed placement trusted", context do
      {:ok, _placement} =
        DCIM.put_current_placement(context.admin, context.web.id, %{
          rack_id: context.rack.id,
          position: 8,
          height_units: 1,
          face: "front",
          confirmed: true
        })

      observe!(context)

      assert {:ok, placement} =
               DCIM.reconcile_placement_evidence(context.reconciler, context.web.id)

      assert placement.confirmed
      assert views(context.web, context.acme) == ~w(inventory trusted)
    end
  end

  describe "exclusive sets" do
    setup context do
      {:ok, set} =
        ResourceGroups.create_group_set(context.admin, %{name: "Environment", exclusive: true})

      {:ok, production} =
        ResourceGroups.create_group(context.admin, %{name: "Production", group_set_id: set.id})

      {:ok, staging} =
        ResourceGroups.create_group(context.admin, %{name: "Staging", group_set_id: set.id})

      {:ok, 1} = ResourceGroups.add_members(context.admin, production, [context.web.id])
      %{production: production, staging: staging}
    end

    test "a container cannot pass down a group that conflicts with a member's", context do
      place!(context, confirmed: true)

      assert {:error, {:exclusive_conflict, [%{resource: "web-01", groups: groups}]}} =
               ResourceGroups.add_members(context.admin, context.staging, [
                 context.rack.resource_id
               ])

      assert groups == ["Production", "Staging"]
      assert views(context.rack.resource_id, context.staging) == []
    end

    test "placing into a container of a conflicting group is refused", context do
      {:ok, 1} =
        ResourceGroups.add_members(context.admin, context.staging, [context.rack.resource_id])

      assert {:error, {:exclusive_conflict, [%{resource: "web-01"}]}} =
               DCIM.put_current_placement(context.admin, context.web.id, %{
                 rack_id: context.rack.id
               })

      assert DCIM.get_rack!(context.admin, context.rack.id).occupancies == []
      assert views(context.web, context.staging) == []
    end

    test "the same group through two paths is one membership", context do
      place!(context, confirmed: true)

      {:ok, 2} =
        ResourceGroups.add_members(context.admin, context.production, [
          context.rack.resource_id,
          context.site.resource_id
        ])

      assert views(context.web, context.production) == ~w(inventory trusted)
    end
  end

  defp observe!(context) do
    {:ok, observation} =
      Inventory.create_observation(context.admin, context.source.id, %{
        observation_id: "placement-#{System.unique_integer([:positive])}",
        observed_at: ~U[2026-10-22 12:00:00.000000Z],
        payload: %{"rack" => "R12"}
      })

    {:ok, _evidence} =
      DCIM.create_placement_evidence(
        context.admin,
        context.source.id,
        observation.id,
        context.web.id,
        %{
          site_identifier: "dc-a",
          rack_identifier: "R12",
          position: 8,
          height_units: 1,
          face: "front",
          confidence: 90,
          observed_at: observation.observed_at
        }
      )
  end

  defp place!(context, confirmed: confirmed) do
    {:ok, placement} =
      DCIM.put_current_placement(context.admin, context.web.id, %{
        rack_id: context.rack.id,
        confirmed: confirmed
      })

    placement
  end

  defp views(%{id: resource_id}, group), do: views(resource_id, group)

  defp views(resource_id, group) do
    Membership
    |> where([row], row.resource_id == ^resource_id and row.group_id == ^group.id)
    |> order_by([row], asc: row.view)
    |> select([row], row.view)
    |> Repo.all()
  end
end
