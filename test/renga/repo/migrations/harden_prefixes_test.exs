defmodule Renga.Repo.Migrations.HardenPrefixesTest do
  @moduledoc """
  The prefix hardening migration (RFD 4, Phase 1) refuses to pick a winner
  among duplicate prefixes: it stops and names them. The same CIDR in
  different routing tables is not a duplicate. Runs against a scratch
  database migrated up to the previous migration.
  """

  use ExUnit.Case, async: false

  @previous_version 20_261_014_120_000
  @migration_version 20_261_015_120_000

  setup do
    scratch_database = "renga_harden_prefixes_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo =
      String.to_atom("renga_harden_prefixes_scratch_#{System.unique_integer([:positive])}")

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

    %{scratch_repo: scratch_repo}
  end

  test "stops and names duplicate prefixes instead of choosing one", %{scratch_repo: repo} do
    Renga.ScratchMigrations.run(repo, :up, to: @previous_version)
    organization_id = insert_organization(repo)

    for vrf <- [nil, nil, "blue", "red"],
        do: insert_prefix(repo, organization_id, "10.0.0.0/24", vrf)

    error =
      assert_raise RuntimeError, fn ->
        Renga.ScratchMigrations.run(repo, :up, to: @migration_version)
      end

    assert error.message =~ "table (global): 10.0.0.0/24 (2 records)"
    refute error.message =~ "blue"
    refute error.message =~ "red"
  end

  test "adds the constraints when every routing table is already unique", %{scratch_repo: repo} do
    Renga.ScratchMigrations.run(repo, :up, to: @previous_version)
    organization_id = insert_organization(repo)

    for vrf <- [nil, "blue"], do: insert_prefix(repo, organization_id, "10.0.0.0/24", vrf)

    assert [@migration_version] = Renga.ScratchMigrations.run(repo, :up, to: @migration_version)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "prefixes_organization_vrf_prefix_index"}}} =
             insert_prefix(repo, organization_id, "10.0.0.0/24", nil)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "prefixes_valid_status"}}} =
             insert_prefix(repo, organization_id, "10.1.0.0/24", nil, "planned")
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

  defp insert_prefix(repo, organization_id, cidr, vrf, status \\ "active") do
    resource_id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO resources (id, organization_id, kind, name, resource_version, inserted_at, updated_at)
      VALUES ('#{resource_id}', '#{organization_id}', 'prefix', 'prefix-#{resource_id}', 1, now(), now())
      """)

    vrf_sql = if vrf, do: "'#{vrf}'", else: "NULL"

    query(repo, """
    INSERT INTO prefixes (id, organization_id, resource_id, prefix, vrf, status, metadata, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization_id}', '#{resource_id}', '#{cidr}', #{vrf_sql}, '#{status}', '{}', now(), now())
    """)
  end

  defp query(repo, sql) do
    Renga.Repo.put_dynamic_repo(repo)
    result = Renga.Repo.query(sql)
    Renga.Repo.put_dynamic_repo(nil)
    result
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
