defmodule Renga.TopologyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Inventory.ResourceRevision
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.Vlan

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization}
  end

  test "creates resource-backed global VLAN namespaces and enforces valid ranges", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "production", [{1, 100}, {200, 299}])
    assert group.resource.kind == "vlan_group"
    assert group.scope_kind == "global"
    assert Enum.map(group.vid_ranges, &{&1.start_vid, &1.end_vid}) == [{1, 100}, {200, 299}]

    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")
    assert vlan.resource.kind == "vlan"
    assert vlan.resource.name == "#{group.id}/42"
    assert vlan.resource.display_name == "Applications"

    assert {:error, :vlan_out_of_range} = vlan_fixture(scope, group, 150, "Outside")

    assert {:error, %Ecto.Changeset{errors: [vid: {_, _}]}} =
             vlan_fixture(scope, group, 4095, "Reserved")
  end

  test "rejects overlapping ranges and range changes that strand VLANs", %{scope: scope} do
    assert {:error, :ranges_required} =
             Topology.create_vlan_group(
               scope,
               %{name: "No ranges", lifecycle_state: "active"},
               %{slug: "no-ranges"},
               []
             )

    assert {:error, %Ecto.Changeset{errors: [start_vid: {_, _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Overlapping ranges", lifecycle_state: "active"},
               %{slug: "overlapping-ranges"},
               [
                 %{start_vid: 1, end_vid: 100},
                 %{start_vid: 100, end_vid: 200}
               ]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "range-change", [{1, 200}])
    assert {:ok, _vlan} = vlan_fixture(scope, group, 100, "Must remain valid")

    assert {:error, :vlan_out_of_range} =
             Topology.replace_vlan_group_ranges(scope, group, [
               %{start_vid: 101, end_vid: 200}
             ])

    stored = Topology.get_vlan_group!(scope, group.id)
    assert Enum.map(stored.vid_ranges, &{&1.start_vid, &1.end_vid}) == [{1, 200}]
  end

  test "uses one null-safe organization-global namespace for ungrouped VLANs", %{scope: scope} do
    assert {:ok, global} = vlan_fixture(scope, nil, 100, "Global")
    assert global.resource.name == "global/100"

    assert {:error, %Ecto.Changeset{}} = vlan_fixture(scope, nil, 100, "Duplicate global")

    assert {:ok, first_group} = vlan_group_fixture(scope, "first", [{1, 4094}])
    assert {:ok, second_group} = vlan_group_fixture(scope, "second", [{1, 4094}])
    assert {:ok, _first} = vlan_fixture(scope, first_group, 100, "First scoped")
    assert {:ok, _second} = vlan_fixture(scope, second_group, 100, "Second scoped")

    assert Enum.map(Topology.list_vlans(scope, nil), & &1.id) == [global.id]
  end

  test "supports typed site and location scopes with tenant-safe foreign keys", %{scope: scope} do
    site = site_fixture(scope, "topology-site")
    location = location_fixture(scope, site, "Network room")

    assert {:ok, site_group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Site VLANs", lifecycle_state: "active"},
               %{slug: "site-vlans", scope_kind: "site", site_id: site.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert site_group.site.id == site.id

    assert {:ok, location_group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Room VLANs", lifecycle_state: "active"},
               %{slug: "room-vlans", scope_kind: "location", location_id: location.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert location_group.location.id == location.id

    assert {:error, %Ecto.Changeset{errors: [scope_kind: {_, _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Invalid scope", lifecycle_state: "active"},
               %{slug: "invalid-scope", scope_kind: "site", location_id: location.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    assert {:error, %Ecto.Changeset{}} =
             Topology.create_vlan_group(
               other_scope,
               %{name: "Foreign site", lifecycle_state: "active"},
               %{slug: "foreign-site", scope_kind: "site", site_id: site.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert_raise Ecto.NoResultsError, fn ->
      Topology.get_vlan_group!(other_scope, site_group.id)
    end
  end

  test "updates VLAN identity and validates moves against the destination namespace", %{
    scope: scope
  } do
    assert {:ok, first_group} = vlan_group_fixture(scope, "source", [{1, 100}])
    assert {:ok, second_group} = vlan_group_fixture(scope, "destination", [{200, 300}])
    assert {:ok, vlan} = vlan_fixture(scope, first_group, 42, "Original")
    original_version = vlan.resource.resource_version
    original_generation = vlan.resource.generation
    original_revision_count = resource_revision_count(vlan.resource_id)

    assert {:error, :vlan_out_of_range} =
             Topology.update_vlan(scope, vlan, %{vid: 150})

    assert {:error, :vlan_out_of_range} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: second_group.id})

    assert resource_revision_count(vlan.resource_id) == original_revision_count

    unchanged = Topology.get_vlan!(scope, vlan.id)
    assert unchanged.resource.name == "#{first_group.id}/42"
    assert unchanged.resource.resource_version == original_version

    assert {:ok, updated} =
             Topology.update_vlan(scope, vlan, %{
               vlan_group_id: second_group.id,
               vid: 250,
               name: "Moved"
             })

    assert updated.vlan_group_id == second_group.id
    assert updated.vid == 250
    assert updated.resource.name == "#{second_group.id}/250"
    assert updated.resource.display_name == "Moved"
    assert updated.resource.resource_version > original_version
    assert updated.resource.generation == original_generation
    assert resource_revision_count(vlan.resource_id) == original_revision_count + 1

    latest_revision =
      ResourceRevision
      |> where([revision], revision.resource_id == ^vlan.resource_id)
      |> order_by([revision], desc: revision.revision)
      |> limit(1)
      |> Repo.one!()

    assert latest_revision.action == "updated"
    assert latest_revision.revision == updated.resource.resource_version
    assert latest_revision.snapshot["name"] == "#{second_group.id}/250"
    assert latest_revision.snapshot["display_name"] == "Moved"
  end

  test "requires an active manager for namespace mutations", %{
    scope: scope,
    organization: organization
  } do
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    viewer_scope = Accounts.scope_for_user(viewer, organization.id)

    assert {:error, :forbidden} =
             Topology.create_vlan_group(
               viewer_scope,
               %{name: "Forbidden", lifecycle_state: "active"},
               %{slug: "forbidden"},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "private", [{1, 100}])
    assert {:error, :forbidden} = vlan_fixture(viewer_scope, group, 10, "Forbidden")
  end

  test "accepts consistently string-keyed resource attributes", %{scope: scope} do
    assert {:ok, group} =
             Topology.create_vlan_group(
               scope,
               %{"name" => "String keyed", "lifecycle_state" => "active"},
               %{"slug" => "string-keyed"},
               [%{"start_vid" => 1, "end_vid" => 100}]
             )

    assert group.resource.kind == "vlan_group"

    assert {:ok, vlan} =
             Topology.create_vlan(
               scope,
               %{"labels" => %{"origin" => "form"}},
               %{"vlan_group_id" => group.id, "vid" => 42, "name" => "String VLAN"}
             )

    assert vlan.resource.name == "#{group.id}/42"
    assert vlan.resource.labels == %{"origin" => "form"}
  end

  test "casts destination groups before locking during VLAN updates", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "update-casting", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [vlan_group_id: {"is invalid", _}]}} =
             Topology.update_vlan(scope, vlan, %{"vlan_group_id" => "not-a-uuid"})

    assert {:ok, ungrouped} =
             Topology.update_vlan(scope, vlan, %{"vlan_group_id" => ""})

    assert is_nil(ungrouped.vlan_group_id)
    assert ungrouped.resource.name == "global/42"
  end

  test "blank VLAN names and group slugs return validation errors", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "blank-validation", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [name: {"can't be blank", _}]}} =
             Topology.update_vlan(scope, vlan, %{"name" => ""})

    refute Topology.change_vlan(vlan, %{name: nil}).valid?

    assert {:error, %Ecto.Changeset{errors: [slug: {"can't be blank", _}]}} =
             Topology.update_vlan_group(scope, group, %{"slug" => ""})

    refute Topology.change_vlan_group(group, %{slug: nil}).valid?
  end

  test "malformed site and location scope IDs return validation errors", %{scope: scope} do
    assert {:error, %Ecto.Changeset{errors: [site_id: {"is invalid", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Bad site", lifecycle_state: "active"},
               %{slug: "bad-site", scope_kind: "site", site_id: "not-a-uuid"},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "scope-update", [{1, 100}])

    assert {:error, %Ecto.Changeset{errors: [location_id: {"is invalid", _}]}} =
             Topology.update_vlan_group(scope, group, %{
               scope_kind: "location",
               location_id: "not-a-uuid"
             })
  end

  test "16-byte non-UUID scope and group IDs return validation errors", %{scope: scope} do
    invalid_uuid = "warehouse worker"

    assert byte_size(invalid_uuid) == 16

    assert {:error, %Ecto.Changeset{errors: [site_id: {"is invalid", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Bad binary site", lifecycle_state: "active"},
               %{slug: "bad-binary-site", scope_kind: "site", site_id: invalid_uuid},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "binary-update", [{1, 100}])

    assert {:error, %Ecto.Changeset{errors: [location_id: {"is invalid", _}]}} =
             Topology.update_vlan_group(scope, group, %{
               scope_kind: "location",
               location_id: invalid_uuid
             })

    assert {:ok, vlan} = vlan_fixture(scope, nil, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [vlan_group_id: {"is invalid", _}]}} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: invalid_uuid})

    assert {:ok, grouped} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: String.upcase(group.id)})

    assert grouped.vlan_group_id == group.id
    assert grouped.resource.name == "#{group.id}/42"
  end

  test "explicit null metadata returns validation errors", %{scope: scope} do
    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Null metadata", lifecycle_state: "active"},
               %{slug: "null-metadata", metadata: nil},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "metadata-update", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.update_vlan_group(scope, group, %{metadata: nil})

    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.update_vlan(scope, vlan, %{metadata: nil})

    assert Topology.get_vlan_group!(scope, group.id).metadata == %{}
    assert Topology.get_vlan!(scope, vlan.id).metadata == %{}
  end

  test "VLAN namespace strings respect database length boundaries", %{scope: scope} do
    max_value = String.duplicate("a", 255)
    oversized = String.duplicate("a", 256)

    assert {:ok, group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Long slug", lifecycle_state: "active"},
               %{slug: max_value},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:error, %Ecto.Changeset{errors: [slug: {_, _}]}} =
             Topology.update_vlan_group(scope, group, %{slug: oversized})

    assert {:ok, vlan} = vlan_fixture(scope, group, 42, max_value)
    assert {:ok, vlan} = Topology.update_vlan(scope, vlan, %{role: max_value})

    assert {:error, %Ecto.Changeset{errors: [name: {_, _}]}} =
             Topology.update_vlan(scope, vlan, %{name: oversized})

    assert {:error, %Ecto.Changeset{errors: [role: {_, _}]}} =
             Topology.update_vlan(scope, vlan, %{role: oversized})
  end

  test "database index rejects duplicate ungrouped VIDs independently of envelope names", %{
    scope: scope
  } do
    {:ok, first_resource} =
      ResourceStore.insert(scope.organization_id, %{
        kind: "vlan",
        name: "direct-global-100-a",
        lifecycle_state: "active"
      })

    {:ok, second_resource} =
      ResourceStore.insert(scope.organization_id, %{
        kind: "vlan",
        name: "direct-global-100-b",
        lifecycle_state: "active"
      })

    assert {:ok, _first_vlan} =
             %Vlan{organization_id: scope.organization_id, resource_id: first_resource.id}
             |> Vlan.changeset(%{vid: 100, name: "First"})
             |> Repo.insert()

    assert {:error, changeset} =
             %Vlan{organization_id: scope.organization_id, resource_id: second_resource.id}
             |> Vlan.changeset(%{vid: 100, name: "Second"})
             |> Repo.insert()

    assert Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
             options[:constraint_name] == "vlans_organization_group_vid_index"
           end)
  end

  test "generic resource updates cannot change derived VLAN envelope identity", %{scope: scope} do
    assert {:ok, vlan} = vlan_fixture(scope, nil, 100, "Global 100")

    assert {:error, changeset} =
             Inventory.update_resource(scope, vlan.resource, %{
               name: "global/200",
               display_name: "Corrupted"
             })

    assert {"is managed by topology", _} = changeset.errors[:name]
    assert {"is managed by topology", _} = changeset.errors[:display_name]

    stored = Topology.get_vlan!(scope, vlan.id)
    assert stored.resource.name == "global/100"
    assert stored.resource.display_name == "Global 100"

    assert {:ok, _global_200} = vlan_fixture(scope, nil, 200, "Global 200")

    assert {:ok, updated_resource} =
             Inventory.update_resource(scope, stored.resource, %{
               labels: %{"managed" => "externally"}
             })

    assert updated_resource.labels == %{"managed" => "externally"}
  end

  test "generic resource creation cannot reserve topology-owned VLAN names", %{scope: scope} do
    assert {:error, changeset} =
             Inventory.create_resource(scope, %{
               kind: "vlan",
               name: "global/200",
               lifecycle_state: "active"
             })

    assert {"must be created through the topology context", _} = changeset.errors[:kind]
    assert {:ok, vlan} = vlan_fixture(scope, nil, 200, "Global 200")
    assert vlan.resource.name == "global/200"
  end

  defp vlan_group_fixture(scope, slug, ranges) do
    Topology.create_vlan_group(
      scope,
      %{name: String.capitalize(slug), lifecycle_state: "active"},
      %{slug: slug, scope_kind: "global", status: "active"},
      Enum.map(ranges, fn {start_vid, end_vid} ->
        %{start_vid: start_vid, end_vid: end_vid}
      end)
    )
  end

  defp vlan_fixture(scope, group, vid, name) do
    Topology.create_vlan(
      scope,
      %{name: "ignored-by-topology"},
      %{vlan_group_id: group && group.id, vid: vid, name: name, status: "active"}
    )
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

  defp location_fixture(scope, site, name) do
    {:ok, location} =
      DCIM.create_location(
        scope,
        %{name: name, lifecycle_state: "active"},
        %{site_id: site.id, status: "active"}
      )

    location
  end

  defp resource_revision_count(resource_id) do
    ResourceRevision
    |> where([revision], revision.resource_id == ^resource_id)
    |> Repo.aggregate(:count)
  end
end
