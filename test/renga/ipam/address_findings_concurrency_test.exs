defmodule Renga.IPAM.AddressFindingsConcurrencyTest do
  @moduledoc "Tests lock ordering with independent connections, not Sandbox ownership sharing."
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Inventory
  alias Renga.IPAM
  alias Renga.Repo

  setup do
    database = "renga_findings_scratch_#{System.unique_integer([:positive])}"
    config = Repo.config()
    admin_config = Keyword.take(config, [:hostname, :port, :username, :password])
    {:ok, admin} = Postgrex.start_link(Keyword.put(admin_config, :database, "postgres"))
    Postgrex.query!(admin, "CREATE DATABASE #{database}", [])
    repo = String.to_atom(database)

    {:ok, _pid} =
      config
      |> Keyword.merge(
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 4,
        name: repo
      )
      |> Repo.start_link()

    Renga.ScratchMigrations.run(repo, :up, all: true)
    Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(Keyword.put(admin_config, :database, "postgres"))
      Postgrex.query!(admin, "DROP DATABASE #{database} WITH (FORCE)", [])
    end)

    %{repo: repo}
  end

  test "standalone reconciliation and an overlapping IPAM write both commit", %{repo: repo} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    {_device, ports} = device_fixture(scope, "server", "lock-order", ~w(eth0))
    prefix_fixture(scope, "10.0.0.0/8")
    address_fixture(scope, ports["eth0"], "192.0.2.5/24")
    parent = self()

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(fn ->
          Inventory.lock_organization!(organization.id)
          [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:writer_locked, pid})

          receive do
            :continue -> IPAM.create_prefix(scope, %{prefix: "198.51.100.0/24"})
          after
            5_000 -> raise "writer was not released"
          end
        end)
      end)

    assert_receive {:writer_locked, writer_pid}, 5_000

    reconciler =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        IPAM.AddressFindings.reconcile(organization.id)
      end)

    # Wait for a real database lock wait before letting IPAM reconcile too.
    assert Enum.any?(1..200, fn _ ->
             [[blocked]] =
               Repo.query!(
                 "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid)))",
                 [writer_pid]
               ).rows

             if !blocked, do: Process.sleep(10)
             blocked
           end)

    send(writer.pid, :continue)
    assert {:ok, {:ok, _prefix}} = Task.await(writer, 10_000)
    assert {:ok, :ok} = Task.await(reconciler, 10_000)

    assert [%{kind: "outside_prefix", status: "open", resolution_key: "192.0.2.5"}] =
             Repo.all(IPAM.AddressFinding)
  end
end
