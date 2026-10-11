defmodule Renga.Repo.Migrations.AddAgentLastContactedAtTest do
  @moduledoc """
  The contact clock starts from each agent's last lease renewal, the best
  record of contact before contact had its own column, and rolls back
  cleanly.
  """

  use ExUnit.Case, async: false

  @before 20_261_025_120_000
  @contact 20_261_026_120_000

  setup do
    scratch_database = "renga_agent_contact_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
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
          start_admin_connection(),
          "DROP DATABASE IF EXISTS #{scratch_database}",
          []
        )
    end)

    Renga.ScratchMigrations.run(scratch_repo, :up, to: @before)
    %{repo: scratch_repo}
  end

  test "backfills contact from the lease and rolls back", %{repo: repo} do
    organization = insert(repo, "organizations", "name, slug", "'Acme', 'acme'")
    leased = insert_agent(repo, organization, "leased")
    unleased = insert_agent(repo, organization, "unleased")

    insert(
      repo,
      "agent_leases",
      "organization_id, agent_id, renewed_at, expires_at",
      "'#{organization}', '#{leased}', '2026-10-01 12:00:00', '2026-10-01 12:01:30'"
    )

    assert [@contact] = Renga.ScratchMigrations.run(repo, :up, to: @contact)

    assert rows(repo, "SELECT id::text, last_contacted_at FROM agents ORDER BY name") == [
             [leased, ~N[2026-10-01 12:00:00.000000]],
             [unleased, nil]
           ]

    assert [@contact] = Renga.ScratchMigrations.run(repo, :down, to: @contact)

    assert [] =
             rows(repo, """
             SELECT 1 FROM information_schema.columns
             WHERE table_name = 'agents' AND column_name = 'last_contacted_at'
             """)
  end

  defp insert_agent(repo, organization, name) do
    source =
      insert(
        repo,
        "sources",
        "organization_id, kind, name",
        "'#{organization}', 'host_agent', '#{name}'"
      )

    insert(
      repo,
      "agents",
      "organization_id, source_id, name, registered_at",
      "'#{organization}', '#{source}', '#{name}', now()"
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
    Renga.Repo.put_dynamic_repo(repo)
    {:ok, %{rows: rows}} = Renga.Repo.query(sql)
    Renga.Repo.put_dynamic_repo(nil)
    rows
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
