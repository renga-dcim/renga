defmodule Renga.Repo.Migrations.KeyObservedAddressesByHostTest do
  @moduledoc """
  The observed-identity migrations (RFD 4, Phase 4) widen the evidence link
  to the reported address, then merge same-host observed addresses on one
  interface into the row with the most recently observed mask, keeping every
  evidence row. Runs against a scratch database migrated up to the last
  Phase 3 migration.
  """

  use ExUnit.Case, async: false

  import Renga.InventoryFixtures, only: [organization_fixture: 0]
  import Renga.TopologyFixtures

  @previous_version 20_261_017_120_000
  @migration_version 20_261_019_120_000

  setup do
    scratch_database = "renga_observed_identity_scratch_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo =
      String.to_atom("renga_observed_identity_scratch_#{System.unique_integer([:positive])}")

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
    %{repo: scratch_repo, database: scratch_database}
  end

  test "merges same-host rows into the most recently observed mask and keeps every report",
       %{repo: repo} do
    organization = insert_organization(repo)
    host = insert_resource(repo, organization, "web-01")
    source = insert_source(repo, organization)
    earlier = insert_observation(repo, organization, source, "2026-08-01 12:00:00")
    later = insert_observation(repo, organization, source, "2026-08-01 13:00:00")

    # eth0: both masks present; the later report wins.
    eth0 = insert_interface(repo, organization, host, "eth0")
    wide = insert_address(repo, organization, host, eth0, "192.0.2.5/24", true)
    narrow = insert_address(repo, organization, host, eth0, "192.0.2.5/32", true)
    insert_evidence(repo, organization, source, earlier, wide, "192.0.2.5/24")
    insert_evidence(repo, organization, source, later, narrow, "192.0.2.5/32")

    # eth1: the later mask has since been withdrawn, so the present one wins.
    eth1 = insert_interface(repo, organization, host, "eth1")
    present = insert_address(repo, organization, host, eth1, "198.51.100.7/24", true)
    withdrawn = insert_address(repo, organization, host, eth1, "198.51.100.7/32", false)
    insert_evidence(repo, organization, source, earlier, present, "198.51.100.7/24")
    insert_evidence(repo, organization, source, later, withdrawn, "198.51.100.7/32")

    # eth2: reported together; the shorter mask wins, as in ingestion.
    eth2 = insert_interface(repo, organization, host, "eth2")
    v6_wide = insert_address(repo, organization, host, eth2, "2001:db8::5/64", true)
    v6_host = insert_address(repo, organization, host, eth2, "2001:db8::5/128", true)
    insert_evidence(repo, organization, source, later, v6_wide, "2001:db8::5/64")
    insert_evidence(repo, organization, source, later, v6_host, "2001:db8::5/128")

    other = insert_address(repo, organization, host, eth2, "2001:db8::6/64", true)

    assert [20_261_018_120_000, @migration_version] =
             Renga.ScratchMigrations.run(repo, :up, to: @migration_version)

    assert addresses(repo) == [
             [eth0, narrow, "192.0.2.5/32"],
             [eth1, present, "198.51.100.7/24"],
             [eth2, v6_wide, "2001:db8::5/64"],
             [eth2, other, "2001:db8::6/64"]
           ]

    # Every reported mask is still evidence, now of the surviving row.
    assert Enum.sort(evidence(repo)) ==
             Enum.sort([
               [narrow, earlier, "192.0.2.5/24"],
               [narrow, later, "192.0.2.5/32"],
               [present, earlier, "198.51.100.7/24"],
               [present, later, "198.51.100.7/32"],
               [v6_wide, later, "2001:db8::5/64"],
               [v6_wide, later, "2001:db8::5/128"]
             ])

    # The host is the identity now: another mask of it is the same row.
    assert {:error, %Postgrex.Error{postgres: %{constraint: "addresses_interface_host_index"}}} =
             insert_address_result(repo, organization, host, eth0, "192.0.2.5/28")

    # Rollback splits the other masks back out, withdrawn, with their evidence.
    assert [@migration_version, 20_261_018_120_000] =
             Renga.ScratchMigrations.run(repo, :down, to: 20_261_018_120_000)

    restored = addresses(repo)
    assert length(restored) == 7

    # Ordered by address, the /24 split sorts before the canonical /32.
    assert [[^eth0, split, "192.0.2.5/24"], [^eth0, ^narrow, "192.0.2.5/32"]] =
             Enum.filter(restored, fn [interface, _id, _address] -> interface == eth0 end)

    assert [["false"]] =
             rows(repo, "SELECT metadata->>'present' FROM addresses WHERE id = '#{split}'")

    assert length(evidence(repo)) == 6

    assert [[^split, ^earlier, "192.0.2.5/24"]] =
             Enum.filter(evidence(repo), fn [address, _observation, _text] -> address == split end)
  end

  test "rollback retains the presence watermark so old reports cannot revive historical masks",
       %{repo: repo} do
    Renga.ScratchMigrations.run(repo, :up, to: @migration_version)
    Renga.Repo.put_dynamic_repo(repo)

    try do
      scope = Renga.Accounts.scope_for(organization_fixture())

      {:ok, source} =
        Renga.Inventory.create_source(scope, %{kind: "host_agent", name: "rollback"})

      [wide] = report_addresses(scope, source, ["192.0.2.10/24"])
      old_observation = wide.metadata["presence_owner"]["observation_id"]
      [current] = report_addresses(scope, source, ["192.0.2.10/32"])

      Renga.ScratchMigrations.run(repo, :down, to: 20_261_018_120_000)
      split = Renga.Repo.get_by!(Renga.Inventory.Address, address: wide.address)
      assert split.metadata["present"] == false
      assert split.metadata["presence_owner"] == current.metadata["presence_owner"]

      assert {:ok, _, false} = Renga.Inventory.reconcile_observation(scope, old_observation)
      assert Renga.Repo.reload!(split).metadata["present"] == false
      assert Renga.Repo.reload!(current).address == current.address
      assert Renga.Repo.reload!(current).metadata["present"] == true
    after
      Renga.Repo.put_dynamic_repo(nil)
    end
  end

  test "merging waits for pending evidence and preserves it instead of cascading it away",
       %{repo: repo, database: database} do
    organization = insert_organization(repo)
    host = insert_resource(repo, organization, "concurrent-merge")
    source = insert_source(repo, organization)
    earlier = insert_observation(repo, organization, source, "2026-08-01 12:00:00")
    later = insert_observation(repo, organization, source, "2026-08-01 13:00:00")
    interface = insert_interface(repo, organization, host, "eth0")
    wide = insert_address(repo, organization, host, interface, "192.0.2.10/24", true)
    narrow = insert_address(repo, organization, host, interface, "192.0.2.10/32", true)
    insert_evidence(repo, organization, source, earlier, wide, "192.0.2.10/24")
    insert_evidence(repo, organization, source, later, narrow, "192.0.2.10/32")
    Renga.ScratchMigrations.run(repo, :up, to: 20_261_018_120_000)

    writer = start_admin_connection(database)
    %{rows: [[writer_pid]]} = Postgrex.query!(writer, "SELECT pg_backend_pid()", [])
    Postgrex.query!(writer, "BEGIN", [])

    try do
      Postgrex.query!(
        writer,
        """
        INSERT INTO address_evidence
          (id, organization_id, address_id, source_id, observation_id, address, observed_at,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), '#{organization}', '#{wide}', '#{source}', id,
               '192.0.2.10/28', observed_at, now(), now()
        FROM observations WHERE id = '#{earlier}'
        """,
        []
      )

      migration =
        Task.async(fn -> Renga.ScratchMigrations.run(repo, :up, to: @migration_version) end)

      # Synchronize on the database lock wait, not on how fast CI runs the migration.
      assert Enum.any?(1..250, fn _ ->
               [[blocked]] =
                 rows(repo, """
                 SELECT EXISTS (
                   SELECT 1 FROM pg_stat_activity
                   WHERE datname = '#{database}' AND #{writer_pid} = ANY(pg_blocking_pids(pid))
                 )
                 """)

               if !blocked, do: Process.sleep(20)
               blocked
             end)

      Postgrex.query!(writer, "COMMIT", [])
      assert [@migration_version] = Task.await(migration, 30_000)

      assert Enum.sort(evidence(repo)) ==
               Enum.sort([
                 [narrow, earlier, "192.0.2.10/24"],
                 [narrow, earlier, "192.0.2.10/28"],
                 [narrow, later, "192.0.2.10/32"]
               ])
    after
      Postgrex.query!(writer, "ROLLBACK", [])
    end
  end

  defp addresses(repo) do
    rows(repo, """
    SELECT interface.name, address.id::text, address.address::text
    FROM addresses AS address JOIN interfaces AS interface ON interface.id = address.interface_id
    ORDER BY interface.name, address.address
    """)
    |> Enum.map(fn [name, id, address] -> [interface_id(repo, name), id, normalize(address)] end)
  end

  defp evidence(repo) do
    rows(repo, """
    SELECT address_id::text, observation_id::text, address::text
    FROM address_evidence ORDER BY address_id, observed_at, address
    """)
    |> Enum.map(fn [address_id, observation_id, address] ->
      [address_id, observation_id, normalize(address)]
    end)
  end

  defp interface_id(repo, name) do
    [[id]] = rows(repo, "SELECT id::text FROM interfaces WHERE name = '#{name}'")
    id
  end

  # PostgreSQL prints a host mask on IPv4 and IPv6 alike only when asked.
  defp normalize(text) do
    if String.contains?(text, "/"),
      do: text,
      else: text <> if(String.contains?(text, ":"), do: "/128", else: "/32")
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

  defp insert_resource(repo, organization_id, name) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO resources (id, organization_id, kind, name, resource_version, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', 'server', '#{name}-#{id}', 1, now(), now())
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

  defp insert_source(repo, organization_id) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO sources (id, organization_id, kind, name, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization_id}', 'host_agent', 'agent-#{id}', now(), now())
      """)

    id
  end

  defp insert_observation(repo, organization_id, source_id, observed_at) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO observations
        (id, organization_id, source_id, idempotency_key, observed_at, payload_digest, payload, inserted_at)
      VALUES ('#{id}', '#{organization_id}', '#{source_id}', '#{id}', '#{observed_at}',
              sha256('#{id}'::bytea), '{}', now())
      """)

    id
  end

  defp insert_address(repo, organization_id, resource_id, interface_id, text, present?) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(
        repo,
        insert_address_sql(id, organization_id, resource_id, interface_id, text, present?)
      )

    id
  end

  defp insert_address_result(repo, organization_id, resource_id, interface_id, text) do
    id = Ecto.UUID.generate()
    query(repo, insert_address_sql(id, organization_id, resource_id, interface_id, text, true))
  end

  defp insert_address_sql(id, organization_id, resource_id, interface_id, text, present?) do
    kind = if String.contains?(text, ":"), do: "ipv6", else: "ipv4"

    """
    INSERT INTO addresses
      (id, organization_id, resource_id, interface_id, kind, address, metadata, inserted_at, updated_at)
    VALUES ('#{id}', '#{organization_id}', '#{resource_id}', '#{interface_id}', '#{kind}',
            '#{text}', '{"present": #{present?}}', now(), now())
    """
  end

  defp insert_evidence(repo, organization_id, source_id, observation_id, address_id, text) do
    {:ok, _} =
      query(repo, """
      INSERT INTO address_evidence
        (id, organization_id, address_id, source_id, observation_id, address, observed_at,
         inserted_at, updated_at)
      SELECT gen_random_uuid(), '#{organization_id}', '#{address_id}', '#{source_id}',
             observation.id, '#{text}', observation.observed_at, now(), now()
      FROM observations AS observation WHERE observation.id = '#{observation_id}'
      """)
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

  defp start_admin_connection(database \\ "postgres") do
    config = Renga.Repo.config()

    {:ok, admin} =
      Postgrex.start_link(
        hostname: Keyword.fetch!(config, :hostname),
        port: Keyword.fetch!(config, :port),
        username: Keyword.fetch!(config, :username),
        password: Keyword.fetch!(config, :password),
        database: database
      )

    admin
  end
end
