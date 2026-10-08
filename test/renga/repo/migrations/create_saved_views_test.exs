defmodule Renga.Repo.Migrations.CreateSavedViewsTest do
  @moduledoc """
  The saved views migration gives every existing organization the "Stale
  inventory" view the sidebar used to hard-code, pinned, so upgrading does
  not empty anyone's sidebar. Runs against a scratch database migrated up to
  the previous migration, keeping the shared test database untouched.
  """

  use ExUnit.Case, async: false

  @previous_version 20_261_002_120_000
  @migration_version 20_261_008_120_000

  setup do
    scratch_database = "renga_saved_views_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo =
      String.to_atom("renga_saved_views_scratch_#{System.unique_integer([:positive])}")

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

  test "pins a Stale inventory view for every existing organization", %{scratch_repo: repo} do
    path = Ecto.Migrator.migrations_path(Renga.Repo)

    Ecto.Migrator.run(Renga.Repo, path, :up,
      to: @previous_version,
      dynamic_repo: repo,
      log: false
    )

    for name <- ["Acme", "Beta"] do
      {:ok, _} =
        query(repo, """
        INSERT INTO organizations (id, name, slug, inserted_at, updated_at)
        VALUES (gen_random_uuid(), '#{name}', '#{String.downcase(name)}', now(), now())
        """)
    end

    assert [@migration_version | _] =
             Ecto.Migrator.run(Renga.Repo, path, :up,
               to: @migration_version,
               dynamic_repo: repo,
               log: false
             )

    assert {:ok, %{rows: rows}} =
             query(repo, """
             SELECT organizations.name, saved_views.name, saved_views.params,
                    saved_views.pinned, saved_views.user_id IS NULL
             FROM saved_views JOIN organizations ON organizations.id = saved_views.organization_id
             ORDER BY organizations.name
             """)

    assert rows == [
             ["Acme", "Stale inventory", %{"freshness" => "stale"}, true, true],
             ["Beta", "Stale inventory", %{"freshness" => "stale"}, true, true]
           ]
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
