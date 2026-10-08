defmodule Renga.DCIM.ElevationTest do
  use Renga.DataCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.DCIM.DesiredPlacement
  alias Renga.DCIM.Elevation
  alias Renga.DCIM.PlacementFinding
  alias Renga.Inventory
  alias Renga.Repo

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(admin, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, hall} = DCIM.create_location(scope, %{name: "Hall A"}, %{site_id: site.id})
    {:ok, other_hall} = DCIM.create_location(scope, %{name: "Hall B"}, %{site_id: site.id})

    {:ok, rack} =
      DCIM.create_rack(scope, %{name: "R12"}, %{
        site_id: site.id,
        location_id: hall.id,
        height_units: 42
      })

    {:ok, other_rack} =
      DCIM.create_rack(scope, %{name: "R13"}, %{site_id: site.id, location_id: hall.id})

    %{
      organization: organization,
      scope: scope,
      site: site,
      hall: hall,
      other_hall: other_hall,
      rack: rack,
      other_rack: other_rack
    }
  end

  test "draws each device once per face it occupies, spanning its units", context do
    %{scope: scope, rack: rack} = context
    web = server_fixture(scope, "web-01")
    storage = resource_fixture(scope, "storage", "nas-01")
    pdu = resource_fixture(scope, "pdu", "pdu-a")
    place!(scope, web, rack, position: 10, height_units: 2, face: "front")
    place!(scope, storage, rack, position: 20, height_units: 4, face: "full")
    place!(scope, pdu, rack, position: 5, height_units: 1, face: "rear")

    elevation = DCIM.rack_elevation(scope, rack.id)

    assert [
             %{resource: %{name: "nas-01"}, position: 20, height: 4, face: "full"},
             %{position: 10, height: 2}
           ] =
             elevation.front

    assert ["nas-01", "pdu-a"] = Enum.map(elevation.rear, & &1.resource.name)
    assert Enum.all?(elevation.front ++ elevation.rear, &(&1.status == :confirmed))

    front = Elevation.free_positions(elevation, 2, "front")
    assert 12 in front
    refute 11 in front
    refute 10 in front
    refute 9 in front
    refute 19 in front
    assert 24 in front
    refute 42 in front

    refute 5 in Elevation.free_positions(elevation, 1, "full")
    assert 5 in Elevation.free_positions(elevation, 1, "front")
    assert Elevation.free_count(elevation, "front") == 36
    refute Elevation.free_unit?(elevation, 23, "rear")
  end

  test "says where a device is planned to go when that is another rack", context do
    %{scope: scope, rack: rack, other_rack: other_rack} = context
    web = server_fixture(scope, "web-01")
    place!(scope, web, rack, position: 10, height_units: 1, face: "front")

    %DesiredPlacement{organization_id: scope.organization_id, resource_id: web.id}
    |> DesiredPlacement.changeset(%{site_id: rack.site_id, rack_id: other_rack.id})
    |> Repo.insert!()

    assert [%{planned_rack: planned}] = DCIM.rack_elevation(scope, rack.id).front
    assert planned.id == other_rack.id
    assert planned.resource.name == "R13"
  end

  test "lists what can go in the rack, nearest first", context do
    %{scope: scope, rack: rack, site: site, hall: hall, other_hall: other_hall} = context
    tor = server_fixture(scope, "tor-placed")
    in_hall = server_fixture(scope, "in-hall")
    at_site = server_fixture(scope, "at-site")
    elsewhere = server_fixture(scope, "elsewhere")
    server_fixture(scope, "nowhere")
    {:ok, _vm} = Inventory.create_resource(scope, %{kind: "vm", name: "vm-01"})

    {:ok, _} = DCIM.put_current_placement(scope, tor.id, %{rack_id: rack.id})

    {:ok, _} =
      DCIM.put_current_placement(scope, in_hall.id, %{site_id: site.id, location_id: hall.id})

    {:ok, _} = DCIM.put_current_placement(scope, at_site.id, %{site_id: site.id})

    {:ok, _} =
      DCIM.put_current_placement(scope, elsewhere.id, %{
        site_id: site.id,
        location_id: other_hall.id
      })

    elevation = DCIM.rack_elevation(scope, rack.id)

    assert [%{resource: %{name: "tor-placed"}, height: 1}] = elevation.in_rack
    assert ["at-site", "in-hall"] = Enum.map(elevation.at_location, & &1.resource.name)
    assert ["nowhere"] = Enum.map(elevation.unplaced, & &1.resource.name)
    assert elevation.unplaced_total == 1
  end

  describe "placing by unit" do
    test "places a device at a unit and face as a confirmed placement", context do
      %{scope: scope, rack: rack} = context
      web = server_fixture(scope, "web-01")

      assert {:ok, placement} = DCIM.place_in_rack(scope, web.id, rack.id, "30", "front")

      assert %{rack_id: rack_id, position: 30, height_units: 1, face: "front", confirmed: true} =
               placement

      assert rack_id == rack.id
      assert placement.provenance["via"] == "elevation"

      assert [%{position: 30}] = DCIM.rack_elevation(scope, rack.id).front
    end

    test "keeps the height a device already has and moves it between units", context do
      %{scope: scope, rack: rack} = context
      web = server_fixture(scope, "web-01")
      place!(scope, web, rack, position: 10, height_units: 2, face: "front")

      assert {:ok, %{position: 20, height_units: 2}} =
               DCIM.place_in_rack(scope, web.id, rack.id, 20, "front")

      assert [%{position: 20, height: 2}] = DCIM.rack_elevation(scope, rack.id).front
    end

    test "refuses overlaps, units past the top, and unknown faces", context do
      %{scope: scope, rack: rack} = context
      web = server_fixture(scope, "web-01")
      db = server_fixture(scope, "db-01")
      place!(scope, web, rack, position: 10, height_units: 2, face: "front")

      assert {:error, %Ecto.Changeset{}} = DCIM.place_in_rack(scope, db.id, rack.id, 11, "front")
      assert {:error, %Ecto.Changeset{}} = DCIM.place_in_rack(scope, db.id, rack.id, 11, "full")
      assert {:ok, _rear} = DCIM.place_in_rack(scope, db.id, rack.id, 11, "rear")

      assert {:error, :rack_position_out_of_bounds} =
               DCIM.place_in_rack(scope, web.id, rack.id, 42, "front")

      assert {:error, :invalid_face} = DCIM.place_in_rack(scope, web.id, rack.id, 1, "side")
    end

    test "only owners and admins place devices", context do
      %{organization: organization, rack: rack, scope: scope} = context
      member = user_fixture()
      organization_membership_fixture(member, organization, %{role: "member"})
      member_scope = Accounts.scope_for_user(member, organization.id)
      web = server_fixture(scope, "web-01")

      assert {:error, :forbidden} = DCIM.place_in_rack(member_scope, web.id, rack.id, 1, "front")
      assert {:error, :forbidden} = DCIM.place_observed(member_scope, web.id, rack.id)
    end
  end

  describe "observed elsewhere" do
    test "evidence for this rack against a confirmed placement elsewhere is placed in one step",
         context do
      %{scope: scope, rack: rack, other_rack: other_rack} = context
      web = server_fixture(scope, "web-01")
      place!(scope, web, other_rack, position: 3, height_units: 1, face: "front")
      observe!(scope, web, rack_identifier: "R12", position: 15, height_units: 1, face: "front")

      assert open_conflict?(scope, web)

      assert [
               %{
                 resource: %{name: "web-01"},
                 via: :evidence,
                 position: 15,
                 height: 1,
                 face: "front",
                 recorded: recorded
               }
             ] = DCIM.rack_elevation(scope, rack.id).observed

      assert recorded.rack.resource.name == "R13"
      assert DCIM.rack_elevation(scope, other_rack.id).observed == []

      assert {:ok, %{position: 15, confirmed: true}} = DCIM.place_observed(scope, web.id, rack.id)
      refute open_conflict?(scope, web)

      elevation = DCIM.rack_elevation(scope, rack.id)
      assert elevation.observed == []
      assert [%{resource: %{name: "web-01"}, position: 15, status: :confirmed}] = elevation.front
    end

    test "observed units another device holds still put the device in the rack", context do
      %{scope: scope, rack: rack, other_rack: other_rack} = context
      web = server_fixture(scope, "web-01")
      db = server_fixture(scope, "db-01")
      place!(scope, web, other_rack, position: 3, height_units: 1, face: "front")
      place!(scope, db, rack, position: 15, height_units: 1, face: "front")
      observe!(scope, web, rack_identifier: "R12", position: 15, height_units: 1, face: "front")

      assert {:ok, %{rack_id: rack_id, position: nil}} =
               DCIM.place_observed(scope, web.id, rack.id)

      assert rack_id == rack.id
      assert [%{resource: %{name: "web-01"}}] = DCIM.rack_elevation(scope, rack.id).in_rack
    end

    test "an LLDP neighbor that is a switch in this rack shows a device placed elsewhere",
         context do
      %{scope: scope, rack: rack, other_rack: other_rack} = context
      switch = resource_fixture(scope, "switch", "leaf-12")
      place!(scope, switch, rack, position: 42, height_units: 1, face: "front")
      web = server_fixture(scope, "web-01")
      place!(scope, web, other_rack, position: 3, height_units: 1, face: "front")
      lldp_fixture(scope, web, switch)

      # A switch's own uplink neighbor is not a device in this rack.
      spine = resource_fixture(scope, "switch", "spine-01")
      lldp_fixture(scope, spine, switch, "uplink")

      assert [%{resource: %{name: "web-01"}, via: :lldp, position: nil}] =
               DCIM.rack_elevation(scope, rack.id).observed

      assert {:ok, %{position: nil, confirmed: true}} =
               DCIM.place_observed(scope, web.id, rack.id)

      elevation = DCIM.rack_elevation(scope, rack.id)
      assert elevation.observed == []
      assert [%{resource: %{name: "web-01"}}] = elevation.in_rack
    end
  end

  defp place!(scope, resource, rack, attrs) do
    {:ok, placement} =
      DCIM.put_current_placement(
        scope,
        resource.id,
        Map.merge(%{rack_id: rack.id, confirmed: true}, Map.new(attrs))
      )

    placement
  end

  defp observe!(scope, resource, attrs) do
    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "scan-#{resource.name}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "scan-#{resource.name}",
        observed_at: DateTime.utc_now(),
        payload: %{}
      })

    {:ok, _evidence} =
      DCIM.create_placement_evidence(
        scope,
        source.id,
        observation.id,
        resource.id,
        Map.merge(%{observed_at: DateTime.utc_now(), confidence: 80}, Map.new(attrs))
      )

    {:ok, _placement} = DCIM.reconcile_placement_evidence(scope, resource.id)
    :ok
  end

  defp open_conflict?(scope, resource) do
    Repo.exists?(
      from finding in PlacementFinding,
        where: finding.organization_id == ^scope.organization_id,
        where: finding.resource_id == ^resource.id,
        where: finding.kind == "confirmed_placement_conflict" and finding.status == "open"
    )
  end
end
