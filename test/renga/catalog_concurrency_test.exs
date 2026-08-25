defmodule Renga.CatalogConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Repo

  test "concurrent revision creation serializes numbering on the catalog type" do
    with_catalog(fn scope, hardware_type ->
      test_process = self()

      first_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result =
              Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "first"})

            send(test_process, :first_revision_ready)

            receive do
              :release_first_revision -> result
            end
          end)
        end)

      assert_receive :first_revision_ready, 1_000

      second_task =
        concurrent(fn ->
          Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "second"})
        end)

      assert Task.yield(second_task, 200) == nil
      send(first_task.pid, :release_first_revision)

      assert {:ok, {:ok, first}} = Task.await(first_task)
      assert {:ok, second} = Task.await(second_task)
      assert Enum.sort([first.revision, second.revision]) == [1, 2]

      assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions
             |> Enum.map(& &1.revision) == [2, 1]
    end)
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

  defp with_catalog(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Concurrency Vendor", lifecycle_state: "active"},
        %{slug: "concurrency-vendor"}
      )

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "Concurrency Hardware", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: "HW-1", device_class: "server"}
      )

    try do
      fun.(scope, hardware_type)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
