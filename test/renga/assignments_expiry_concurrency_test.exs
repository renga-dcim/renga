defmodule Renga.AssignmentsExpiryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.Roles
  alias Renga.Roles.Assignment

  test "concurrent expiry sweeps record one durable event" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    owner = user_fixture()
    viewer = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})
    viewer_membership = organization_membership_fixture(viewer, organization, %{role: "viewer"})
    scope = Accounts.scope_for_user(owner, organization.id)

    future = DateTime.add(Renga.Time.utc_now_ms(), 1, :hour)

    {:ok, assignment} =
      Assignments.assign(scope, viewer_membership.id, %{
        "role" => "member",
        "valid_until" => future
      })

    Repo.update_all(
      where(Assignment, id: ^assignment.id),
      set: [valid_until: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
    )

    results =
      1..2
      |> Task.async_stream(
        fn _worker ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Assignments.sweep_expired()
          after
            Sandbox.checkin(Repo)
          end
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, count} -> count end)

    try do
      assert Enum.sum(results) == 1

      assert context_events(scope, assignment.id) == ["role_expired"]
      assert Repo.get!(Assignment, assignment.id).expired_at

      {:ok, removable} =
        Assignments.assign(scope, viewer_membership.id, %{
          "role" => "admin",
          "valid_until" => future
        })

      Repo.update_all(
        where(Assignment, id: ^removable.id),
        set: [valid_until: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
      )

      sweep = concurrent(fn -> Assignments.sweep_expired() end)
      removal = concurrent(fn -> Assignments.unassign(scope, removable.id) end)
      _sweep_count = Task.await(sweep, 5_000)
      assert {:ok, _assignment} = Task.await(removal, 5_000)

      assert context_events(scope, removable.id) == ["role_expired"]
      refute Repo.get(Assignment, removable.id)

      {:ok, role} =
        Roles.create_role(scope, %{
          "name" => "Expiring concurrent role",
          "permissions" => ["dcim.edit"]
        })

      {:ok, cascading} =
        Assignments.assign(scope, viewer_membership.id, %{
          "role" => role.id,
          "valid_until" => future
        })

      Repo.update_all(
        where(Assignment, id: ^cascading.id),
        set: [valid_until: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
      )

      sweep = concurrent(fn -> Assignments.sweep_expired() end)
      deletion = concurrent(fn -> Roles.delete_role(scope, role) end)
      _sweep_count = Task.await(sweep, 5_000)
      assert {:ok, _role} = Task.await(deletion, 5_000)

      assert context_events(scope, cascading.id) == ["role_expired"]
      refute Repo.get(Assignment, cascading.id)
    after
      Repo.delete!(organization)
      Repo.delete!(owner)
      Repo.delete!(viewer)
      Sandbox.checkin(Repo)
    end
  end

  defp concurrent(operation) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        operation.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp context_events(scope, assignment_id) do
    scope
    |> Inventory.list_activity()
    |> Enum.filter(&(&1.kind == "role_expired" and &1.metadata["assignment_id"] == assignment_id))
    |> Enum.map(& &1.kind)
  end
end
