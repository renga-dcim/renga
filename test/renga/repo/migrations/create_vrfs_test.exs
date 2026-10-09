defmodule Renga.Repo.Migrations.CreateVrfsTest do
  @moduledoc """
  The VRF migration (RFD 4, Phase 2) turns each legacy routing-table string
  into a VRF, or into the global table, and never merges two tables on its
  own: it stops with a report until an operator renames them to one
  spelling. Runs against a scratch database migrated up to the previous
  migration.
  """

  use ExUnit.Case, async: false

  @previous_version 20_261_015_120_000
  @migration_version 20_261_016_120_000

  setup do
    scratch_database = "renga_create_vrfs_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo =
      String.to_atom("renga_create_vrfs_scratch_#{System.unique_integer([:positive])}")

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

  test "maps each legacy table to a VRF or to the global table", %{repo: repo} do
    acme = insert_organization(repo)
    globex = insert_organization(repo)

    global = insert_prefix(repo, acme, "10.0.0.0/24", nil)
    blue = insert_prefix(repo, acme, "10.0.0.0/24", "blue")
    red = insert_prefix(repo, acme, "10.0.0.0/24", " Red ")
    host = insert_prefix(repo, acme, "10.0.0.1/32", "blue")
    default = insert_prefix(repo, globex, "192.0.2.0/24", "default")
    other_blue = insert_prefix(repo, globex, "192.0.2.0/24", "Blue")

    assert [@migration_version] = Renga.ScratchMigrations.run(repo, :up, to: @migration_version)

    assert vrfs(repo, acme) == ["blue", "Red"]
    assert vrfs(repo, globex) == ["Blue"]

    assert vrf_name(repo, global) == nil
    assert vrf_name(repo, blue) == "blue"
    assert vrf_name(repo, host) == "blue"
    assert vrf_name(repo, red) == "Red"
    # A lone `default` table was always the global table.
    assert vrf_name(repo, default) == nil
    assert vrf_name(repo, other_blue) == "Blue"

    # Each VRF has an envelope with its creation revision.
    assert [[3, 3]] =
             rows(repo, """
             SELECT count(DISTINCT resources.id), count(resource_revisions.id)
             FROM vrfs
             JOIN resources ON resources.id = vrfs.resource_id AND resources.kind = 'vrf'
             JOIN resource_revisions ON resource_revisions.resource_id = resources.id
                                    AND resource_revisions.action = 'created'
             """)

    # Prefix labels follow the namespace they landed in, as revisions.
    assert label(repo, red) == {"10.0.0.0/24 (Red)", ["updated"]}
    assert label(repo, default) == {"192.0.2.0/24", ["updated"]}
    # Labels that already match, host routes included, are left alone.
    assert label(repo, host) == {"10.0.0.1 (blue)", []}
    assert label(repo, blue) == {"10.0.0.0/24 (blue)", []}

    # One CIDR per namespace, with global counted as one.
    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "prefixes_organization_vrf_prefix_index"}}} =
             query(repo, """
             INSERT INTO prefixes (id, organization_id, resource_id, prefix, status, metadata, inserted_at, updated_at)
             VALUES (gen_random_uuid(), '#{acme}', '#{insert_resource(repo, acme)}', '10.0.0.0/24', 'active', '{}', now(), now())
             """)

    # VRF names cannot differ only by case again.
    assert {:error, %Postgrex.Error{postgres: %{constraint: "vrfs_organization_name_index"}}} =
             query(repo, """
             INSERT INTO vrfs (id, organization_id, resource_id, name, inserted_at, updated_at)
             VALUES (gen_random_uuid(), '#{acme}', '#{insert_resource(repo, acme)}', 'BLUE', now(), now())
             """)
  end

  test "stops on a merge, and runs once the tables are renamed to one", %{repo: repo} do
    organization = insert_organization(repo)

    lower = insert_prefix(repo, organization, "10.0.0.0/24", "blue")
    upper = insert_prefix(repo, organization, "10.0.0.0/25", "Blue")
    global = insert_prefix(repo, organization, "10.1.0.0/16", nil)
    default = insert_prefix(repo, organization, "10.2.0.0/16", "default")
    red = insert_prefix(repo, organization, "10.3.0.0/16", "red")

    error =
      assert_raise RuntimeError, fn ->
        Renga.ScratchMigrations.run(repo, :up, to: @migration_version)
      end

    assert error.message =~ "organization #{organization}, table \"blue\": "
    assert error.message =~ ~s["blue" (1 prefix)]
    assert error.message =~ ~s["Blue" (1 prefix)]
    assert error.message =~ "organization #{organization}, Global: "
    assert error.message =~ "Global (no table) (1 prefix)"
    assert error.message =~ ~s["default" (1 prefix)]
    refute error.message =~ "red"

    # Nothing was applied.
    assert [[nil]] = rows(repo, "SELECT to_regclass('vrfs')::text")
    assert [["blue"]] = rows(repo, "SELECT vrf FROM prefixes WHERE id = '#{lower}'")

    # The operator approves both merges by renaming in the prefix edit form.
    {:ok, _} = query(repo, "UPDATE prefixes SET vrf = 'blue' WHERE id = '#{upper}'")
    {:ok, _} = query(repo, "UPDATE prefixes SET vrf = NULL WHERE id = '#{default}'")

    assert [@migration_version] = Renga.ScratchMigrations.run(repo, :up, to: @migration_version)

    assert vrfs(repo, organization) == ["blue", "red"]
    assert vrf_name(repo, lower) == "blue"
    assert vrf_name(repo, upper) == "blue"
    assert vrf_name(repo, global) == nil
    assert vrf_name(repo, default) == nil
    assert vrf_name(repo, red) == "red"
  end

  test "rolls back to routing-table names", %{repo: repo} do
    organization = insert_organization(repo)
    global = insert_prefix(repo, organization, "10.0.0.0/24", nil)
    blue = insert_prefix(repo, organization, "10.0.0.0/24", "blue")
    red = insert_prefix(repo, organization, "10.0.1.0/24", " Red ")
    default_org = insert_organization(repo)
    default = insert_prefix(repo, default_org, "10.0.0.0/24", "default")

    Renga.ScratchMigrations.run(repo, :up, to: @migration_version)
    Renga.ScratchMigrations.run(repo, :down, to: @migration_version)

    assert [[nil]] = rows(repo, "SELECT vrf FROM prefixes WHERE id = '#{global}'")
    assert [["blue"]] = rows(repo, "SELECT vrf FROM prefixes WHERE id = '#{blue}'")
    assert [["Red"]] = rows(repo, "SELECT vrf FROM prefixes WHERE id = '#{red}'")
    assert [[nil]] = rows(repo, "SELECT vrf FROM prefixes WHERE id = '#{default}'")
    assert [[nil]] = rows(repo, "SELECT to_regclass('vrfs')::text")
    assert [[0]] = rows(repo, "SELECT count(*) FROM resources WHERE kind = 'vrf'")
  end

  defp vrfs(repo, organization_id) do
    repo
    |> rows(
      "SELECT name FROM vrfs WHERE organization_id = '#{organization_id}' ORDER BY lower(name)"
    )
    |> List.flatten()
  end

  defp vrf_name(repo, prefix_id) do
    [[name]] =
      rows(repo, """
      SELECT vrfs.name FROM prefixes LEFT JOIN vrfs ON vrfs.id = prefixes.vrf_id
      WHERE prefixes.id = '#{prefix_id}'
      """)

    name
  end

  defp label(repo, prefix_id) do
    [[display_name, actions]] =
      rows(repo, """
      SELECT resources.display_name,
             coalesce(array_agg(resource_revisions.action) FILTER (WHERE resource_revisions.id IS NOT NULL), '{}')
      FROM prefixes
      JOIN resources ON resources.id = prefixes.resource_id
      LEFT JOIN resource_revisions ON resource_revisions.resource_id = resources.id
      WHERE prefixes.id = '#{prefix_id}'
      GROUP BY resources.display_name
      """)

    {display_name, actions}
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

  defp insert_resource(repo, organization_id, display_name \\ nil) do
    resource_id = Ecto.UUID.generate()
    display_name_sql = if display_name, do: "'#{display_name}'", else: "NULL"

    {:ok, _} =
      query(repo, """
      INSERT INTO resources (id, organization_id, kind, name, display_name, resource_version, inserted_at, updated_at)
      VALUES ('#{resource_id}', '#{organization_id}', 'prefix', 'prefix-#{resource_id}', #{display_name_sql}, 1, now(), now())
      """)

    resource_id
  end

  # Labelled as Phase 1 labelled them: the CIDR and the table as typed.
  defp insert_prefix(repo, organization_id, cidr, vrf) do
    id = Ecto.UUID.generate()
    address = String.replace_suffix(cidr, "/32", "")
    label = if vrf, do: "#{address} (#{vrf})", else: address
    resource_id = insert_resource(repo, organization_id, label)
    vrf_sql = if vrf, do: "'#{vrf}'", else: "NULL"

    {:ok, _} =
      query(repo, """
      INSERT INTO prefixes (id, organization_id, resource_id, prefix, vrf, status, metadata, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', '#{resource_id}', '#{cidr}', #{vrf_sql}, 'active', '{}', now(), now())
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
