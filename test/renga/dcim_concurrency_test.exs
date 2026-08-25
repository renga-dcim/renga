defmodule Renga.DCIMConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Repo

  test "concurrent inverse-parent updates cannot create a site group cycle" do
    with_dcim(fn scope ->
      {:ok, first} =
        DCIM.create_site_group(scope, %{name: "First region", lifecycle_state: "active"})

      {:ok, second} =
        DCIM.create_site_group(scope, %{name: "Second region", lifecycle_state: "active"})

      {first_task, release_first} =
        held_mutation(fn -> DCIM.update_site_group(scope, first, %{parent_id: second.id}) end)

      assert_receive :mutation_ready, 1_000

      second_task =
        concurrent(fn -> DCIM.update_site_group(scope, second, %{parent_id: first.id}) end)

      assert Task.yield(second_task, 200) == nil
      release_first.()

      assert {:ok, {:ok, updated_first}} = Task.await(first_task)
      assert updated_first.parent_id == second.id
      assert {:error, :hierarchy_cycle} = Task.await(second_task)
    end)
  end

  test "concurrent inverse-parent updates cannot create a location cycle" do
    with_dcim(fn scope ->
      site = site_fixture(scope, "hierarchy-race")
      {:ok, first} = location_fixture(scope, site, "First")
      {:ok, second} = location_fixture(scope, site, "Second")

      {first_task, release_first} =
        held_mutation(fn -> DCIM.update_location(scope, first, %{parent_id: second.id}) end)

      assert_receive :mutation_ready, 1_000

      second_task =
        concurrent(fn -> DCIM.update_location(scope, second, %{parent_id: first.id}) end)

      assert Task.yield(second_task, 200) == nil
      release_first.()

      assert {:ok, {:ok, updated_first}} = Task.await(first_task)
      assert updated_first.parent_id == second.id
      assert {:error, :hierarchy_cycle} = Task.await(second_task)
    end)
  end

  test "concurrent overlapping current placements allow only one occupant" do
    with_dcim(fn scope ->
      site = site_fixture(scope, "occupancy-race")
      {:ok, rack} = rack_fixture(scope, site, "R01", 42)
      first = resource_fixture(scope, "first-race-server")
      second = resource_fixture(scope, "second-race-server")

      placement_attrs = %{rack_id: rack.id, position: 20, height_units: 2, face: "front"}

      {first_task, release_first} =
        held_mutation(fn -> DCIM.put_current_placement(scope, first.id, placement_attrs) end)

      assert_receive :mutation_ready, 1_000

      second_task =
        concurrent(fn -> DCIM.put_current_placement(scope, second.id, placement_attrs) end)

      assert Task.yield(second_task, 200) == nil
      release_first.()

      assert {:ok, {:ok, _placement}} = Task.await(first_task)

      assert {:error, %Ecto.Changeset{errors: [units: {"overlaps existing rack occupancy", _}]}} =
               Task.await(second_task)

      assert length(DCIM.get_rack!(scope, rack.id).occupancies) == 1
    end)
  end

  test "concurrent placement prevents a rack shrink from stranding occupancy" do
    with_dcim(fn scope ->
      site = site_fixture(scope, "geometry-race")
      {:ok, rack} = rack_fixture(scope, site, "R02", 20)
      resource = resource_fixture(scope, "geometry-race-server")

      {placement_task, release_placement} =
        held_mutation(fn ->
          DCIM.put_current_placement(scope, resource.id, %{
            rack_id: rack.id,
            position: 19,
            height_units: 2,
            face: "full"
          })
        end)

      assert_receive :mutation_ready, 1_000
      resize_task = concurrent(fn -> DCIM.update_rack(scope, rack, %{height_units: 18}) end)

      assert Task.yield(resize_task, 200) == nil
      release_placement.()

      assert {:ok, {:ok, _placement}} = Task.await(placement_task)
      assert {:error, :occupied_units_out_of_bounds} = Task.await(resize_task)
      assert DCIM.get_rack!(scope, rack.id).height_units == 20
    end)
  end

  test "evidence reconciliation cannot overwrite a concurrently confirmed placement" do
    with_dcim(fn scope ->
      site = site_fixture(scope, "confirmation-race")
      {:ok, first_rack} = rack_fixture(scope, site, "R-CONFIRMED", 42)
      {:ok, evidence_rack} = rack_fixture(scope, site, "R-EVIDENCE", 42)
      resource = resource_fixture(scope, "confirmation-race-server")
      {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "race-import"})

      assert {:ok, _initial} =
               DCIM.put_current_placement(scope, resource.id, %{
                 rack_id: first_rack.id,
                 position: 1,
                 height_units: 1,
                 face: "front"
               })

      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "confirmation-race-observation",
          observed_at: ~U[2026-08-25 17:30:00.000000Z],
          payload: %{"rack" => evidence_rack.resource.name}
        })

      assert {:ok, _evidence} =
               DCIM.create_placement_evidence(
                 scope,
                 source.id,
                 observation.id,
                 resource.id,
                 %{
                   site_identifier: site.slug,
                   rack_identifier: evidence_rack.resource.name,
                   position: 10,
                   height_units: 1,
                   face: "front",
                   observed_at: observation.observed_at
                 }
               )

      {confirmation_task, release_confirmation} =
        held_mutation(fn ->
          DCIM.put_current_placement(scope, resource.id, %{
            rack_id: first_rack.id,
            position: 2,
            height_units: 1,
            face: "front",
            confirmed: true
          })
        end)

      assert_receive :mutation_ready, 1_000

      reconciliation_task =
        concurrent(fn -> DCIM.reconcile_placement_evidence(scope, resource.id) end)

      assert Task.yield(reconciliation_task, 200) == nil
      release_confirmation.()

      assert {:ok, {:ok, confirmed}} = Task.await(confirmation_task)
      assert confirmed.confirmed
      assert {:ok, unchanged} = Task.await(reconciliation_task)
      assert unchanged.id == confirmed.id
      assert unchanged.confirmed
      assert unchanged.rack_id == first_rack.id
    end)
  end

  test "rack moves wait for concurrent placement and reject contradictory containment" do
    with_dcim(fn scope ->
      site = site_fixture(scope, "rack-location-race")
      {:ok, first_location} = location_fixture(scope, site, "First room")
      {:ok, second_location} = location_fixture(scope, site, "Second room")
      {:ok, rack} = rack_fixture(scope, site, "R-LOCATION-RACE", 42, first_location.id)
      resource = resource_fixture(scope, "rack-location-race-server")

      {placement_task, release_placement} =
        held_mutation(fn ->
          DCIM.put_current_placement(scope, resource.id, %{
            rack_id: rack.id,
            position: 1,
            height_units: 1,
            face: "front"
          })
        end)

      assert_receive :mutation_ready, 1_000

      move_task =
        concurrent(fn -> DCIM.update_rack(scope, rack, %{location_id: second_location.id}) end)

      assert Task.yield(move_task, 200) == nil
      release_placement.()

      assert {:ok, {:ok, placement}} = Task.await(placement_task)
      assert placement.location_id == first_location.id
      assert {:error, :rack_has_placements} = Task.await(move_task)
      assert DCIM.get_rack!(scope, rack.id).location_id == first_location.id
    end)
  end

  test "manager mutations wait for concurrent role revocation and recheck authorization" do
    with_dcim_context(fn scope, _user, _organization, membership ->
      test_process = self()

      demotion_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            updated =
              membership
              |> Renga.Accounts.OrganizationMembership.changeset(%{role: "member"})
              |> Repo.update!()

            send(test_process, :demotion_ready)

            receive do
              :release_demotion -> updated
            end
          end)
        end)

      assert_receive :demotion_ready, 1_000

      mutation_task =
        concurrent(fn ->
          DCIM.create_site(
            scope,
            %{name: "Denied after demotion", lifecycle_state: "active"},
            %{slug: "denied-after-demotion", status: "active"}
          )
        end)

      assert Task.yield(mutation_task, 200) == nil
      send(demotion_task.pid, :release_demotion)

      assert {:ok, %Renga.Accounts.OrganizationMembership{role: "member"}} =
               Task.await(demotion_task)

      assert {:error, :forbidden} = Task.await(mutation_task)
    end)
  end

  defp held_mutation(mutation) do
    test_process = self()

    task =
      concurrent(fn ->
        Repo.transaction(fn ->
          result = mutation.()
          send(test_process, :mutation_ready)

          receive do
            :release_mutation -> result
          end
        end)
      end)

    {task, fn -> send(task.pid, :release_mutation) end}
  end

  defp concurrent(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp with_dcim(fun) do
    with_dcim_context(fn scope, _user, _organization, _membership -> fun.(scope) end)
  end

  defp with_dcim_context(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    try do
      fun.(scope, user, organization, membership)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
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
    DCIM.create_location(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{site_id: site.id, status: "active"}
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
