defmodule Renga.DCIMTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization, user: user}
  end

  test "creates tenant-scoped sites and same-site nested locations", %{scope: scope} do
    site = site_fixture(scope, "dc-a")

    assert {:ok, floor} =
             DCIM.create_location(
               scope,
               %{name: "Floor 1", lifecycle_state: "active"},
               %{site_id: site.id, kind: "floor", status: "active"}
             )

    assert {:ok, room} =
             DCIM.create_location(
               scope,
               %{name: "Room 101", lifecycle_state: "active"},
               %{site_id: site.id, parent_id: floor.id, kind: "room", status: "active"}
             )

    assert room.parent_id == floor.id

    assert DCIM.get_site!(scope, site.id).locations |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([floor.id, room.id])

    other_site = site_fixture(scope, "dc-b")

    assert {:error, :parent_site_mismatch} =
             DCIM.create_location(
               scope,
               %{name: "Impossible room", lifecycle_state: "active"},
               %{site_id: other_site.id, parent_id: floor.id, status: "active"}
             )
  end

  test "rejects location cycles", %{scope: scope} do
    site = site_fixture(scope, "cycle-site")
    {:ok, parent} = location_fixture(scope, site, "Parent")
    {:ok, child} = location_fixture(scope, site, "Child", parent.id)

    assert {:error, :hierarchy_cycle} =
             DCIM.update_location(scope, parent, %{parent_id: child.id})
  end

  test "rejects site group cycles", %{scope: scope} do
    {:ok, region} =
      DCIM.create_site_group(scope, %{name: "EMEA", lifecycle_state: "active"})

    {:ok, country} =
      DCIM.create_site_group(
        scope,
        %{name: "Germany", lifecycle_state: "active"},
        %{parent_id: region.id}
      )

    assert {:error, :hierarchy_cycle} =
             DCIM.update_site_group(scope, region, %{parent_id: country.id})
  end

  test "prevents cross-tenant reads and containment", %{scope: scope} do
    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    site = site_fixture(scope, "private-site")

    assert_raise Ecto.NoResultsError, fn -> DCIM.get_site!(other_scope, site.id) end

    assert {:error, %Ecto.Changeset{}} =
             DCIM.create_rack(
               other_scope,
               %{name: "Foreign rack", lifecycle_state: "active"},
               %{site_id: site.id, height_units: 42, status: "active"}
             )
  end

  test "current rack placement is atomic, bounded, and face-aware", %{scope: scope} do
    site = site_fixture(scope, "placement-site")
    {:ok, rack} = rack_fixture(scope, site, "R01", 20)
    first = resource_fixture(scope, "server-01")
    second = resource_fixture(scope, "server-02")

    assert {:ok, placement} =
             DCIM.put_current_placement(scope, first.id, %{
               rack_id: rack.id,
               position: 10,
               height_units: 2,
               face: "front",
               confirmed: true
             })

    assert placement.site_id == site.id
    assert length(DCIM.get_rack!(scope, rack.id).occupancies) == 1

    assert {:error, %Ecto.Changeset{errors: [units: {"overlaps existing rack occupancy", _}]}} =
             DCIM.put_current_placement(scope, second.id, %{
               rack_id: rack.id,
               position: 11,
               height_units: 1,
               face: "front"
             })

    assert {:ok, _rear_placement} =
             DCIM.put_current_placement(scope, second.id, %{
               rack_id: rack.id,
               position: 11,
               height_units: 1,
               face: "rear"
             })

    third = resource_fixture(scope, "server-03")

    assert {:error, :rack_position_out_of_bounds} =
             DCIM.put_current_placement(scope, third.id, %{
               rack_id: rack.id,
               position: 20,
               height_units: 2,
               face: "front"
             })
  end

  test "rack geometry cannot strand occupancy", %{scope: scope} do
    site = site_fixture(scope, "resize-site")
    {:ok, rack} = rack_fixture(scope, site, "R02", 20)
    resource = resource_fixture(scope, "server-04")

    assert {:ok, _placement} =
             DCIM.put_current_placement(scope, resource.id, %{
               rack_id: rack.id,
               position: 18,
               height_units: 2,
               face: "full"
             })

    assert {:error, :occupied_units_out_of_bounds} =
             DCIM.update_rack(scope, rack, %{height_units: 18})
  end

  test "partial current-placement updates revalidate effective rack bounds", %{scope: scope} do
    site = site_fixture(scope, "partial-update-site")
    {:ok, rack} = rack_fixture(scope, site, "R-PARTIAL", 42)
    resource = resource_fixture(scope, "partial-update-server")

    assert {:ok, _placement} =
             DCIM.put_current_placement(scope, resource.id, %{
               rack_id: rack.id,
               position: 40,
               height_units: 2,
               face: "front"
             })

    assert {:error, :rack_position_out_of_bounds} =
             DCIM.put_current_placement(scope, resource.id, %{
               position: 42,
               height_units: 2,
               face: "front"
             })

    assert {:error, :rack_position_out_of_bounds} =
             DCIM.put_current_placement(scope, resource.id, %{height_units: 4})

    assert [occupancy] = DCIM.get_rack!(scope, rack.id).occupancies
    assert occupancy.units.lower == 40
    assert occupancy.units.upper == 42
  end

  test "rack location changes are rejected while desired or current placements reference it", %{
    scope: scope
  } do
    site = site_fixture(scope, "rack-move-site")
    {:ok, first_location} = location_fixture(scope, site, "First room")
    {:ok, second_location} = location_fixture(scope, site, "Second room")
    {:ok, current_rack} = rack_fixture(scope, site, "R-CURRENT", 42, first_location.id)
    {:ok, desired_rack} = rack_fixture(scope, site, "R-DESIRED", 42, first_location.id)
    current_resource = resource_fixture(scope, "rack-move-current")
    desired_resource = resource_fixture(scope, "rack-move-desired")

    assert {:ok, _placement} =
             DCIM.put_current_placement(scope, current_resource.id, %{
               rack_id: current_rack.id,
               position: 1,
               height_units: 1,
               face: "front"
             })

    assert {:ok, _placement} =
             DCIM.put_desired_placement(scope, desired_resource.id, %{
               rack_id: desired_rack.id,
               position: 1,
               height_units: 1,
               face: "front"
             })

    assert {:error, :rack_has_placements} =
             DCIM.update_rack(scope, current_rack, %{location_id: second_location.id})

    assert {:error, :rack_has_placements} =
             DCIM.update_rack(scope, desired_rack, %{location_id: second_location.id})
  end

  test "desired placement reports conflicts without reserving rack units", %{scope: scope} do
    site = site_fixture(scope, "desired-site")
    {:ok, rack} = rack_fixture(scope, site, "R03", 42)
    current_resource = resource_fixture(scope, "current-server")
    desired_resource = resource_fixture(scope, "moving-server")

    {:ok, _placement} =
      DCIM.put_current_placement(scope, current_resource.id, %{
        rack_id: rack.id,
        position: 5,
        height_units: 2,
        face: "full"
      })

    assert {:ok, desired} =
             DCIM.put_desired_placement(scope, desired_resource.id, %{
               rack_id: rack.id,
               position: 6,
               height_units: 1,
               face: "rear"
             })

    assert desired.rack_id == rack.id

    assert [%{kind: "blocked_move", resource_id: resource_id}] =
             DCIM.list_placement_findings(scope)

    assert resource_id == desired_resource.id
    assert length(DCIM.get_rack!(scope, rack.id).occupancies) == 2
  end

  test "desired feasibility handles bounds, self occupancy, and later occupancy changes", %{
    scope: scope
  } do
    site = site_fixture(scope, "desired-refresh-site")
    {:ok, rack} = rack_fixture(scope, site, "R-DESIRED-REFRESH", 10)
    moving = resource_fixture(scope, "moving-resource")
    blocker = resource_fixture(scope, "blocking-resource")

    assert {:ok, _current} =
             DCIM.put_current_placement(scope, moving.id, %{
               rack_id: rack.id,
               position: 4,
               height_units: 2,
               face: "front"
             })

    assert {:ok, _desired} =
             DCIM.put_desired_placement(scope, moving.id, %{
               rack_id: rack.id,
               position: 5,
               height_units: 1,
               face: "front"
             })

    refute Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _desired} =
             DCIM.put_desired_placement(scope, moving.id, %{
               rack_id: rack.id,
               position: 10,
               height_units: 2,
               face: "front"
             })

    assert Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _desired} =
             DCIM.put_desired_placement(scope, moving.id, %{
               rack_id: rack.id,
               position: 7,
               height_units: 1,
               face: "front"
             })

    refute Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _current} =
             DCIM.put_current_placement(scope, blocker.id, %{
               rack_id: rack.id,
               position: 7,
               height_units: 1,
               face: "front"
             })

    assert Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _removed} = DCIM.remove_current_placement(scope, blocker.id)
    refute Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _desired} =
             DCIM.put_desired_placement(scope, moving.id, %{
               rack_id: rack.id,
               position: 10,
               height_units: 2,
               face: "front"
             })

    assert Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, expanded_rack} = DCIM.update_rack(scope, rack, %{height_units: 12})
    refute Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))

    assert {:ok, _shrunk_rack} = DCIM.update_rack(scope, expanded_rack, %{height_units: 10})
    assert Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "blocked_move"))
  end

  test "retains placement evidence and marks it stale independently", %{scope: scope} do
    resource = resource_fixture(scope, "observed-server")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "facility-import"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "placement-1",
        observed_at: ~U[2026-08-25 12:00:00.000000Z],
        payload: %{"rack" => "R04"}
      })

    assert {:ok, evidence} =
             DCIM.create_placement_evidence(scope, source.id, observation.id, resource.id, %{
               rack_identifier: "R04",
               confidence: 80,
               observed_at: observation.observed_at
             })

    assert evidence.stale_at == nil
    assert {:ok, {1, nil}} = DCIM.mark_placement_evidence_stale(scope, source.id)
    assert Renga.Repo.reload!(evidence).stale_at
  end

  test "only complete placement snapshots stale omitted evidence", %{scope: scope} do
    resource = resource_fixture(scope, "snapshot-server")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "snapshot-import",
        metadata: %{"placement_snapshot_policy" => "complete"}
      })

    {:ok, old_observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "snapshot-old",
        observed_at: ~U[2026-08-25 10:00:00.000000Z],
        payload: %{"rack" => "R05"}
      })

    {:ok, evidence} =
      DCIM.create_placement_evidence(scope, source.id, old_observation.id, resource.id, %{
        rack_identifier: "R05",
        observed_at: old_observation.observed_at
      })

    {:ok, partial} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "snapshot-partial",
        observed_at: ~U[2026-08-25 11:00:00.000000Z],
        payload: %{"section_completeness" => %{"placement" => false}}
      })

    assert {:error, :incomplete_snapshot} =
             DCIM.mark_omitted_placement_evidence_stale(scope, source.id, partial.id, [])

    refute Renga.Repo.reload!(evidence).stale_at

    {:ok, complete} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "snapshot-complete",
        observed_at: ~U[2026-08-25 12:00:00.000000Z],
        payload: %{"section_completeness" => %{"placement" => true}}
      })

    assert {:ok, {1, nil}} =
             DCIM.mark_omitted_placement_evidence_stale(scope, source.id, complete.id, [])

    assert Renga.Repo.reload!(evidence).stale_at == complete.observed_at
  end

  test "observation completeness cannot stale evidence without complete source policy", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "partial-policy-server")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "partial-policy"})

    {:ok, old_observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "partial-policy-old",
        observed_at: ~U[2026-08-25 10:00:00.000000Z],
        payload: %{"rack" => "R01"}
      })

    {:ok, evidence} =
      DCIM.create_placement_evidence(scope, source.id, old_observation.id, resource.id, %{
        rack_identifier: "R01",
        observed_at: old_observation.observed_at
      })

    {:ok, complete_claim} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "partial-policy-claim",
        observed_at: ~U[2026-08-25 12:00:00.000000Z],
        payload: %{"section_completeness" => %{"placement" => true}}
      })

    assert {:error, :source_not_complete} =
             DCIM.mark_omitted_placement_evidence_stale(
               scope,
               source.id,
               complete_claim.id,
               []
             )

    refute Renga.Repo.reload!(evidence).stale_at
  end

  test "reconciles unambiguous evidence and preserves confirmed placement conflicts", %{
    scope: scope
  } do
    site = site_fixture(scope, "evidence-site")
    {:ok, rack} = rack_fixture(scope, site, "EVID-R01", 42)
    resource = resource_fixture(scope, "evidence-server")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "rack-import"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "evidence-placement-1",
        observed_at: ~U[2026-08-25 13:00:00.000000Z],
        payload: %{"rack" => "EVID-R01"}
      })

    {:ok, _evidence} =
      DCIM.create_placement_evidence(scope, source.id, observation.id, resource.id, %{
        site_identifier: site.slug,
        rack_identifier: rack.resource.name,
        position: 8,
        height_units: 1,
        face: "front",
        confidence: 90,
        observed_at: observation.observed_at
      })

    assert {:ok, placement} = DCIM.reconcile_placement_evidence(scope, resource.id)
    assert placement.rack_id == rack.id
    refute placement.confirmed

    assert [occupancy] = DCIM.get_rack!(scope, rack.id).occupancies
    assert occupancy.current_placement.evidence_observed_at == observation.observed_at
    refute occupancy.current_placement.evidence_stale?

    assert {:ok, {1, nil}} = DCIM.mark_placement_evidence_stale(scope, source.id)
    assert [stale_occupancy] = DCIM.get_rack!(scope, rack.id).occupancies
    assert stale_occupancy.current_placement.evidence_stale?

    other_resource = resource_fixture(scope, "confirmed-server")

    assert {:ok, confirmed} =
             DCIM.put_current_placement(scope, other_resource.id, %{
               site_id: site.id,
               confirmed: true,
               provenance: %{"confirmed_by" => "operator"}
             })

    {:ok, conflict_observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "evidence-placement-2",
        observed_at: ~U[2026-08-25 14:00:00.000000Z],
        payload: %{"rack" => "EVID-R01"}
      })

    {:ok, _conflict_evidence} =
      DCIM.create_placement_evidence(
        scope,
        source.id,
        conflict_observation.id,
        other_resource.id,
        %{
          site_identifier: site.slug,
          rack_identifier: rack.resource.name,
          position: 12,
          height_units: 1,
          face: "front",
          confidence: 90,
          observed_at: conflict_observation.observed_at
        }
      )

    assert {:ok, unchanged} = DCIM.reconcile_placement_evidence(scope, other_resource.id)
    assert unchanged.id == confirmed.id

    assert Enum.any?(
             DCIM.list_placement_findings(scope),
             &(&1.resource_id == other_resource.id and
                 &1.kind == "confirmed_placement_conflict")
           )
  end

  test "reports simultaneous placement assertions without inventing a current placement", %{
    scope: scope
  } do
    site = site_fixture(scope, "simultaneous-evidence-site")
    {:ok, first_rack} = rack_fixture(scope, site, "SIM-R01", 42)
    {:ok, second_rack} = rack_fixture(scope, site, "SIM-R02", 42)
    resource = resource_fixture(scope, "simultaneous-evidence-server")
    {:ok, first_source} = Inventory.create_source(scope, %{kind: "manual", name: "first-import"})

    {:ok, second_source} =
      Inventory.create_source(scope, %{kind: "manual", name: "second-import"})

    observed_at = ~U[2026-08-25 15:00:00.000000Z]

    for {source, rack, suffix} <- [
          {first_source, first_rack, "first"},
          {second_source, second_rack, "second"}
        ] do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "simultaneous-#{suffix}",
          observed_at: observed_at,
          payload: %{"rack" => rack.resource.name}
        })

      assert {:ok, _evidence} =
               DCIM.create_placement_evidence(
                 scope,
                 source.id,
                 observation.id,
                 resource.id,
                 %{
                   site_identifier: site.slug,
                   rack_identifier: rack.resource.name,
                   position: 10,
                   height_units: 1,
                   face: "front",
                   confidence: 90,
                   observed_at: observed_at
                 }
               )
    end

    assert {:ok, nil} = DCIM.reconcile_placement_evidence(scope, resource.id)

    finding_kinds = DCIM.list_placement_findings(scope) |> Enum.map(& &1.kind)
    assert "source_disagreement" in finding_kinds
    assert "multiple_current_placements" in finding_kinds
    assert Enum.any?(DCIM.list_unplaced_resources(scope), &(&1.id == resource.id))
  end

  test "partial geometry reconciles only the containment that evidence proves", %{scope: scope} do
    site = site_fixture(scope, "partial-evidence-site")
    {:ok, rack} = rack_fixture(scope, site, "R-PARTIAL-EVIDENCE", 42)
    resource = resource_fixture(scope, "partial-evidence-server")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "partial-evidence"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "partial-evidence-observation",
        observed_at: ~U[2026-08-25 16:00:00.000000Z],
        payload: %{"rack" => rack.resource.name}
      })

    assert {:ok, _evidence} =
             DCIM.create_placement_evidence(scope, source.id, observation.id, resource.id, %{
               site_identifier: site.slug,
               rack_identifier: rack.resource.name,
               position: 10,
               observed_at: observation.observed_at
             })

    assert {:ok, placement} = DCIM.reconcile_placement_evidence(scope, resource.id)
    assert placement.rack_id == rack.id
    assert placement.position == nil
    assert placement.height_units == nil
    assert placement.face == nil
    assert DCIM.get_rack!(scope, rack.id).occupancies == []
  end

  test "rack resolution does not discard a contradictory location assertion", %{scope: scope} do
    site = site_fixture(scope, "contradictory-evidence-site")
    {:ok, first_location} = location_fixture(scope, site, "Observed room")
    {:ok, second_location} = location_fixture(scope, site, "Actual room")
    {:ok, rack} = rack_fixture(scope, site, "R-CONTRADICT", 42, second_location.id)
    resource = resource_fixture(scope, "contradictory-evidence-server")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "contradictory-import"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "contradictory-evidence",
        observed_at: ~U[2026-08-25 16:30:00.000000Z],
        payload: %{"rack" => rack.resource.name}
      })

    assert {:ok, _evidence} =
             DCIM.create_placement_evidence(scope, source.id, observation.id, resource.id, %{
               location_identifier: first_location.resource.name,
               rack_identifier: rack.resource.name,
               observed_at: observation.observed_at
             })

    assert {:ok, nil} = DCIM.reconcile_placement_evidence(scope, resource.id)
    assert Enum.any?(DCIM.list_placement_findings(scope), &(&1.kind == "containment_conflict"))
  end

  test "rechecks manager authorization inside mutations", %{
    scope: scope,
    organization: organization,
    user: user
  } do
    membership =
      Renga.Repo.get_by!(Renga.Accounts.OrganizationMembership,
        organization_id: organization.id,
        user_id: user.id
      )

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:error, :forbidden} =
             DCIM.create_site(
               scope,
               %{name: "Denied", lifecycle_state: "active"},
               %{slug: "denied", status: "active"}
             )
  end

  test "rechecks authorization for evidence and finding mutations", %{
    scope: scope,
    organization: organization,
    user: user
  } do
    resource = resource_fixture(scope, "authorization-evidence-server")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "authorization-source"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "authorization-observation",
        observed_at: ~U[2026-08-25 17:00:00.000000Z],
        payload: %{}
      })

    membership =
      Renga.Repo.get_by!(Renga.Accounts.OrganizationMembership,
        organization_id: organization.id,
        user_id: user.id
      )

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:error, :forbidden} =
             DCIM.create_placement_evidence(
               scope,
               source.id,
               observation.id,
               resource.id,
               %{observed_at: observation.observed_at}
             )

    assert {:error, :forbidden} = DCIM.mark_placement_evidence_stale(scope, source.id)

    assert {:error, :forbidden} =
             DCIM.mark_omitted_placement_evidence_stale(
               scope,
               source.id,
               observation.id,
               []
             )

    assert {:error, :forbidden} =
             DCIM.put_placement_finding(scope, resource.id, %{
               kind: "unknown_location",
               message: "Denied"
             })

    assert {:error, :forbidden} =
             DCIM.resolve_placement_finding(scope, resource.id, "unknown_location")
  end

  test "trusted placement reconciler scopes can process source evidence", %{
    scope: scope,
    organization: organization
  } do
    site = site_fixture(scope, "trusted-reconciler-site")
    resource = resource_fixture(scope, "trusted-reconciler-server")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "trusted-reconciler"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "trusted-reconciler-observation",
        observed_at: ~U[2026-08-25 17:15:00.000000Z],
        payload: %{}
      })

    system_scope = Accounts.scope_for(organization, %{roles: ["placement_reconciler"]})

    assert {:ok, _evidence} =
             DCIM.create_placement_evidence(
               system_scope,
               source.id,
               observation.id,
               resource.id,
               %{site_identifier: site.slug, observed_at: observation.observed_at}
             )

    assert {:ok, placement} = DCIM.reconcile_placement_evidence(system_scope, resource.id)
    assert placement.site_id == site.id
  end

  defp site_fixture(scope, slug) do
    {:ok, site} =
      DCIM.create_site(
        scope,
        %{name: String.upcase(slug), lifecycle_state: "active"},
        %{slug: slug, status: "active", time_zone: "Etc/UTC"}
      )

    site
  end

  defp location_fixture(scope, site, name, parent_id \\ nil) do
    DCIM.create_location(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{site_id: site.id, parent_id: parent_id, status: "active"}
    )
  end

  defp rack_fixture(scope, site, name, height, location_id \\ nil) do
    DCIM.create_rack(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{
        site_id: site.id,
        location_id: location_id,
        height_units: height,
        width: "19_inch",
        status: "active"
      }
    )
  end

  defp resource_fixture(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: name,
        lifecycle_state: "active"
      })

    resource
  end
end
