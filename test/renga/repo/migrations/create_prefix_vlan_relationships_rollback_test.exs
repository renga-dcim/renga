defmodule Renga.Repo.Migrations.CreatePrefixVlanRelationshipsRollbackTest do
  @moduledoc """
  Verifies the prefix/VLAN relationship migration rollback and re-apply against
  a scratch database migrated from zero, keeping the shared test database and
  its sandboxed connections untouched.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @migration_version 20_261_002_120_000
  @migration_path "priv/repo/migrations/20261002120000_create_prefix_vlan_relationships.exs"

  setup_all do
    scratch_database = "renga_migration_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()

    # A previous failed run may have left the scratch database behind.
    {:ok, %Postgrex.Result{}} =
      Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])

    create_database(admin, scratch_database)

    # The scratch repository uses a plain pool because the sandbox only hands
    # connections to ownership owners, and the migrator spawns its own. It must
    # be named: an unnamed instance would silently route queries to the default
    # application repository.
    scratch_repo =
      String.to_atom("renga_migration_scratch_repo_#{System.unique_integer([:positive])}")

    {:ok, _} =
      Renga.Repo.config()
      |> Keyword.merge(
        database: scratch_database,
        pool: DBConnection.ConnectionPool,
        pool_size: 12,
        name: scratch_repo
      )
      |> Renga.Repo.start_link()

    # Migrating from zero pins the whole chain, including the association.
    migrated = Renga.ScratchMigrations.run(scratch_repo, :up, all: true)

    assert @migration_version in migrated

    on_exit(fn ->
      # The scratch repo is linked to the test process and stops with it, so
      # its connections are gone by the time the scratch database is dropped.
      # The admin connection from setup_all died with the same process, so a
      # fresh one is started here for the cleanup query.
      Process.sleep(100)
      drop_database(start_admin_connection(), scratch_database)
    end)

    %{admin: admin, scratch_repo: scratch_repo}
  end

  test "rolls back and re-applies the association schema", %{
    scratch_repo: scratch_repo
  } do
    # The scratch setup already migrated the chain, so the migration module is
    # normally loaded; only require the file when running this test cold.
    migration_module =
      if Code.ensure_loaded?(Renga.Repo.Migrations.CreatePrefixVlanRelationships) do
        Renga.Repo.Migrations.CreatePrefixVlanRelationships
      else
        [{migration_module, _bytecode}] = Code.require_file(@migration_path)
        migration_module
      end

    assert migration_module == Renga.Repo.Migrations.CreatePrefixVlanRelationships

    assert :ok =
             Ecto.Migrator.down(Renga.Repo, @migration_version, migration_module,
               dynamic_repo: scratch_repo,
               log: false
             )

    # The rollback dropped the association table while everything else remains.
    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} =
             query_scratch(scratch_repo, "SELECT * FROM prefix_vlan_relationships")

    # Re-applying a migration older than the latest one is exactly what Ecto
    # warns about, so the expected warning is captured rather than printed.
    {result, log} =
      with_log(fn ->
        Ecto.Migrator.up(Renga.Repo, @migration_version, migration_module,
          dynamic_repo: scratch_repo,
          log: false
        )
      end)

    assert result == :ok
    assert log =~ "You are running migration #{@migration_version}"

    # Re-applying restores an empty association table.
    assert {:ok, %Postgrex.Result{num_rows: 0}} =
             query_scratch(scratch_repo, "SELECT * FROM prefix_vlan_relationships")
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

  defp create_database(admin, scratch_database) do
    {:ok, %Postgrex.Result{}} =
      Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])
  end

  defp drop_database(admin, scratch_database) do
    {:ok, %Postgrex.Result{}} =
      Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
  end

  defp query_scratch(scratch_repo, sql) do
    Renga.Repo.put_dynamic_repo(scratch_repo)
    result = Renga.Repo.query(sql)
    Renga.Repo.put_dynamic_repo(nil)
    result
  end
end
