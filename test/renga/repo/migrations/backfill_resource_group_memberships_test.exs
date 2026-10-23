defmodule Renga.Repo.Migrations.BackfillResourceGroupMembershipsTest do
  @moduledoc """
  Container inheritance must be correct immediately after upgrading, before
  any later placement or membership mutation happens.
  """

  use ExUnit.Case, async: false

  @before 20_261_101_153_700
  @backfill 20_261_101_153_750

  setup do
    scratch_database = "renga_group_backfill_#{System.unique_integer([:positive])}"
    admin = Renga.ScratchMigrations.start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])
    scratch_repo = String.to_atom("#{scratch_database}_repo")

    {:ok, _} =
      Renga.Repo.config()
      |> Keyword.merge(
        database: scratch_database,
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        name: scratch_repo
      )
      |> Renga.Repo.start_link()

    on_exit(fn ->
      Process.sleep(100)

      {:ok, _} =
        Postgrex.query(
          Renga.ScratchMigrations.start_admin_connection(),
          "DROP DATABASE IF EXISTS #{scratch_database}",
          []
        )
    end)

    Renga.ScratchMigrations.run(scratch_repo, :up, to: @before)
    %{repo: scratch_repo}
  end

  test "backfills inherited memberships and rollback restores direct-only rows", %{repo: repo} do
    data = seed_placed_resource(repo)
    group = insert_group(repo, data.organization, "Managed")
    insert_member(repo, data.organization, group, data.rack_resource)
    insert_direct_projection(repo, data.organization, group, data.rack_resource)

    assert [@backfill] = Renga.ScratchMigrations.run(repo, :up, to: @backfill)

    assert memberships(repo, data.organization, group) ==
             Enum.sort([
               [data.rack_resource, "inventory"],
               [data.rack_resource, "trusted"],
               [data.server, "inventory"],
               [data.server, "trusted"]
             ])

    assert [@backfill] = Renga.ScratchMigrations.run(repo, :down, to: @backfill)

    assert memberships(repo, data.organization, group) == [
             [data.rack_resource, "inventory"],
             [data.rack_resource, "trusted"]
           ]
  end

  test "refuses an inherited exclusive conflict with actionable details", %{repo: repo} do
    data = seed_placed_resource(repo)
    group_set = insert_group_set(repo, data.organization, "Environment")
    production = insert_group(repo, data.organization, "Production", group_set)
    staging = insert_group(repo, data.organization, "Staging", group_set)

    insert_member(repo, data.organization, production, data.server)
    insert_member(repo, data.organization, staging, data.rack_resource)
    insert_direct_projection(repo, data.organization, production, data.server, group_set)
    insert_direct_projection(repo, data.organization, staging, data.rack_resource, group_set)

    error =
      assert_raise Postgrex.Error, fn ->
        Renga.ScratchMigrations.run(repo, :up, to: @backfill)
      end

    assert Exception.message(error) =~ "cannot backfill inherited group memberships"
    assert Exception.message(error) =~ "server-01"
    assert Exception.message(error) =~ "Environment"
    assert Exception.message(error) =~ "Production, Staging"
  end

  defp seed_placed_resource(repo) do
    organization = insert(repo, "organizations", "name, slug", "'Acme', 'acme'")
    site_resource = insert_resource(repo, organization, "site", "dc-a")
    rack_resource = insert_resource(repo, organization, "rack", "rack-01")
    server = insert_resource(repo, organization, "server", "server-01")

    site =
      insert(
        repo,
        "sites",
        "organization_id, resource_id, slug",
        "'#{organization}', '#{site_resource}', 'dc-a'"
      )

    rack =
      insert(
        repo,
        "racks",
        "organization_id, resource_id, site_id",
        "'#{organization}', '#{rack_resource}', '#{site}'"
      )

    insert(
      repo,
      "current_placements",
      "organization_id, resource_id, site_id, rack_id, confirmed",
      "'#{organization}', '#{server}', '#{site}', '#{rack}', true"
    )

    %{organization: organization, rack_resource: rack_resource, server: server}
  end

  defp insert_resource(repo, organization, kind, name) do
    insert(
      repo,
      "resources",
      "organization_id, kind, name, resource_version",
      "'#{organization}', '#{kind}', '#{name}', nextval('resource_revision_sequence')"
    )
  end

  defp insert_group_set(repo, organization, name) do
    insert(
      repo,
      "resource_group_sets",
      "organization_id, name, exclusive",
      "'#{organization}', '#{name}', true"
    )
  end

  defp insert_group(repo, organization, name, group_set \\ nil) do
    group_set = if group_set, do: "'#{group_set}'", else: "NULL"

    insert(
      repo,
      "resource_groups",
      "organization_id, group_set_id, name",
      "'#{organization}', #{group_set}, '#{name}'"
    )
  end

  defp insert_member(repo, organization, group, resource) do
    id = Ecto.UUID.generate()

    query(repo, """
    INSERT INTO resource_group_members
      (id, organization_id, group_id, resource_id, inserted_at)
    VALUES ('#{id}', '#{organization}', '#{group}', '#{resource}', now())
    """)
  end

  defp insert_direct_projection(repo, organization, group, resource, group_set \\ nil) do
    group_set = if group_set, do: "'#{group_set}'", else: "NULL"

    for view <- ~w(inventory trusted) do
      query(repo, """
      INSERT INTO resource_group_memberships
        (organization_id, resource_id, view, group_id, group_set_id)
      VALUES ('#{organization}', '#{resource}', '#{view}', '#{group}', #{group_set})
      """)
    end
  end

  defp memberships(repo, organization, group) do
    rows(
      repo,
      """
      SELECT resource_id::text, view
        FROM resource_group_memberships
       WHERE organization_id = '#{organization}' AND group_id = '#{group}'
       ORDER BY resource_id, view
      """
    )
  end

  defp insert(repo, table, columns, values) do
    id = Ecto.UUID.generate()

    [[^id]] =
      rows(repo, """
      INSERT INTO #{table} (id, #{columns}, inserted_at, updated_at)
      VALUES ('#{id}', #{values}, now(), now()) RETURNING id::text
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
end
