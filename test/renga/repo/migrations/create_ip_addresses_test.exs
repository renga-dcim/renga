defmodule Renga.Repo.Migrations.CreateIpAddressesTest do
  @moduledoc """
  The IP-address migration (RFD 4, Phase 3) turns each shipped managed
  address into an `ip_address` with an envelope in the global table, an
  assignment to the interface it remembers, and its intended mask recovered
  from that interface's current observation. Runs against a scratch
  database migrated up to the previous migration.
  """

  use ExUnit.Case, async: false

  @previous_version 20_261_016_120_000
  @migration_version 20_261_017_120_000

  setup do
    scratch_database = "renga_create_ip_addresses_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo =
      String.to_atom("renga_create_ip_addresses_scratch_#{System.unique_integer([:positive])}")

    {:ok, _} =
      Renga.Repo.config()
      |> Keyword.merge(
        database: scratch_database,
        pool: DBConnection.ConnectionPool,
        pool_size: 4,
        name: scratch_repo
      )
      |> Renga.Repo.start_link()

    on_exit(fn ->
      Process.sleep(100)

      {:ok, _} =
        Postgrex.query(
          start_admin_connection(),
          "DROP DATABASE IF EXISTS #{scratch_database}",
          []
        )
    end)

    Renga.ScratchMigrations.run(scratch_repo, :up, to: @previous_version)
    %{repo: scratch_repo}
  end

  test "gives each managed address an envelope, an assignment, and its intended mask",
       %{repo: repo} do
    organization = insert_organization(repo)
    host = insert_resource(repo, organization, "server", "web-01")
    eth0 = insert_interface(repo, organization, host, "eth0")
    eth1 = insert_interface(repo, organization, host, "eth1")

    insert_address(repo, organization, host, eth0, "192.0.2.5/24", ~s({"present": true}))
    insert_address(repo, organization, host, eth1, "2001:db8::5/64", ~s({"present": false}))

    observed = insert_managed(repo, organization, "192.0.2.5/32", eth0)
    withdrawn = insert_managed(repo, organization, "2001:db8::5/128", eth1)
    orphan = insert_managed(repo, organization, "198.51.100.7/32", nil)

    assert [@migration_version] = Renga.ScratchMigrations.run(repo, :up, to: @migration_version)

    # The observed mask comes back; a withdrawn or missing observation leaves
    # the host length.
    assert address(repo, observed) == "192.0.2.5/24"
    assert address(repo, withdrawn) == "2001:db8::5/128"
    assert address(repo, orphan) == "198.51.100.7/32"

    assert [[nil, "allocated", "ordinary", nil]] =
             rows(repo, """
             SELECT DISTINCT vrf_id::text, allocation_state, role, management_mode
             FROM ip_addresses
             """)

    assert [
             ["192.0.2.5", "ip_address", "active", 1],
             ["198.51.100.7", "ip_address", "active", 1],
             ["2001:db8::5", "ip_address", "active", 1]
           ] =
             rows(repo, """
             SELECT resources.display_name, resources.kind, resources.lifecycle_state,
                    count(resource_revisions.id)::int
             FROM ip_addresses
             JOIN resources ON resources.id = ip_addresses.resource_id
             JOIN resource_revisions ON resource_revisions.resource_id = resources.id
                                    AND resource_revisions.action = 'created'
             GROUP BY 1, 2, 3 ORDER BY 1
             """)

    assert assignments(repo) ==
             MapSet.new([{observed, eth0}, {withdrawn, eth1}])

    # One managed address per namespace and host, whatever the mask.
    assert {:error, %Postgrex.Error{postgres: %{constraint: "ip_addresses_namespace_host_index"}}} =
             query(repo, """
             INSERT INTO ip_addresses
               (id, organization_id, resource_id, address, inserted_at, updated_at)
             VALUES (gen_random_uuid(), '#{organization}',
                     '#{insert_resource(repo, organization, "ip_address", "dup")}',
                     '192.0.2.5/32', now(), now())
             """)
  end

  test "rolls back to host-length managed addresses with their interface", %{repo: repo} do
    organization = insert_organization(repo)
    host = insert_resource(repo, organization, "server", "web-01")
    eth0 = insert_interface(repo, organization, host, "eth0")
    insert_address(repo, organization, host, eth0, "192.0.2.5/24", ~s({"present": true}))
    managed = insert_managed(repo, organization, "192.0.2.5/32", eth0)

    Renga.ScratchMigrations.run(repo, :up, to: @migration_version)
    Renga.ScratchMigrations.run(repo, :down, to: @migration_version)

    assert [["192.0.2.5/32", ^eth0]] =
             rows(repo, """
             SELECT address::text, interface_id::text FROM managed_addresses
             WHERE id = '#{managed}'
             """)

    assert [[0]] = rows(repo, "SELECT count(*)::int FROM resources WHERE kind = 'ip_address'")
    assert [[nil]] = rows(repo, "SELECT to_regclass('ip_addresses')::text")
  end

  defp address(repo, id) do
    [[text]] = rows(repo, "SELECT address::text FROM ip_addresses WHERE id = '#{id}'")
    text
  end

  defp assignments(repo) do
    repo
    |> rows("SELECT ip_address_id::text, interface_id::text FROM ip_address_assignments")
    |> MapSet.new(fn [ip_address, interface] -> {ip_address, interface} end)
  end

  defp insert_organization(repo) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO organizations (id, name, slug, inserted_at, updated_at)
      VALUES ('#{id}', 'Acme', 'acme-#{System.unique_integer([:positive])}', now(), now())
      """)

    id
  end

  defp rows(repo, sql) do
    {:ok, %{rows: rows}} = query(repo, sql)
    rows
  end

  defp query(repo, sql) do
    Renga.Repo.put_dynamic_repo(repo)
    result = Renga.Repo.query(sql)
    Renga.Repo.put_dynamic_repo(nil)
    result
  end

  defp insert_resource(repo, organization_id, kind, name) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO resources (id, organization_id, kind, name, resource_version, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', '#{kind}', '#{name}-#{id}', 1, now(), now())
      """)

    id
  end

  defp insert_interface(repo, organization_id, resource_id, name) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO interfaces (id, organization_id, resource_id, name, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', '#{resource_id}', '#{name}', now(), now())
      """)

    id
  end

  defp insert_address(repo, organization_id, resource_id, interface_id, text, metadata) do
    kind = if String.contains?(text, ":"), do: "ipv6", else: "ipv4"

    {:ok, _} =
      query(repo, """
      INSERT INTO addresses
        (id, organization_id, resource_id, interface_id, kind, address, metadata, inserted_at, updated_at)
      VALUES (gen_random_uuid(), '#{organization_id}', '#{resource_id}', '#{interface_id}',
              '#{kind}', '#{text}', '#{metadata}', now(), now())
      """)
  end

  defp insert_managed(repo, organization_id, text, interface_id) do
    id = Ecto.UUID.generate()
    interface_sql = if interface_id, do: "'#{interface_id}'", else: "NULL"

    {:ok, _} =
      query(repo, """
      INSERT INTO managed_addresses (id, organization_id, address, interface_id, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', '#{text}', #{interface_sql}, now(), now())
      """)

    id
  end

  defp start_admin_connection do
    config = Renga.Repo.config()

    {:ok, admin} =
      Postgrex.start_link(
        hostname: Keyword.fetch!(config, :hostname),
        port: Keyword.fetch!(config, :port),
        username: Keyword.fetch!(config, :username),
        password: Keyword.fetch!(config, :password),
        database: "postgres"
      )

    admin
  end
end
