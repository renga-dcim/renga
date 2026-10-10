defmodule Renga.Repo.Migrations.IpamFindingsDomainsPlanMigrationsTest do
  @moduledoc """
  The RFD 4 migrations from Phase 5 on, run in order against one scratch
  database: strict prefixes, address findings and their workflows,
  routing-domain claims, wide workflow keys, and the addressing plan.

  Each step's database-level invariants are checked with raw SQL, so they
  hold whatever the application code does, and the whole run rolls back to
  the schema it started from.
  """

  use ExUnit.Case, async: false

  @before_strict 20_261_019_120_000
  @strict 20_261_020_120_000
  @address_findings 20_261_021_120_000
  @finding_workflows 20_261_022_120_000
  @routing_domains 20_261_023_120_000
  @wide_keys 20_261_024_120_000
  @plan_levels 20_261_025_120_000

  setup do
    scratch_database = "renga_ipam_late_migrations_#{System.unique_integer([:positive])}"
    admin = start_admin_connection()
    {:ok, _} = Postgrex.query(admin, "DROP DATABASE IF EXISTS #{scratch_database}", [])
    {:ok, _} = Postgrex.query(admin, "CREATE DATABASE #{scratch_database}", [])

    # A named plain pool: the sandbox only serves ownership owners, and an
    # unnamed instance would route queries to the default repository.
    scratch_repo = String.to_atom("#{scratch_database}_repo")

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

    Renga.ScratchMigrations.run(scratch_repo, :up, to: @before_strict)
    %{repo: scratch_repo}
  end

  test "each migration enforces its invariants in the database and all roll back",
       %{repo: repo} do
    acme = insert_organization(repo)
    other = insert_organization(repo)
    agent = insert_source(repo, acme, "host_agent")
    provider = insert_source(repo, acme, "vm_provider")
    host = insert_resource(repo, acme, "server", "web-01")
    eth0 = insert_interface(repo, acme, host, "eth0")
    foreign_host = insert_resource(repo, other, "server", "db-01")
    foreign_eth0 = insert_interface(repo, other, foreign_host, "eth0")

    # Strict prefixes default to the normal address policy.
    assert [@strict] = up(repo, @strict)

    assert [["false", "NO"]] =
             rows(repo, """
             SELECT column_default, is_nullable FROM information_schema.columns
             WHERE table_name = 'prefixes' AND column_name = 'strict'
             """)

    # Address findings belong to an interface of their own organization and
    # are resolved exactly when they carry a resolution time.
    assert [@address_findings] = up(repo, @address_findings)
    assert {:ok, _} = insert_finding(repo, acme, eth0, "open", "NULL")

    assert violates(insert_finding(repo, acme, foreign_eth0, "open", "NULL")) ==
             "address_findings_tenant_interface_fkey"

    assert violates(insert_finding(repo, acme, eth0, "resolved", "NULL")) ==
             "address_findings_resolution_state"

    assert violates(insert_finding(repo, acme, eth0, "open", "now()")) ==
             "address_findings_resolution_state"

    # Only one open finding per interface, kind, and key.
    assert violates(insert_finding(repo, acme, eth0, "open", "NULL")) ==
             "address_findings_open_resolution_index"

    # The address domain joins the shared workflow.
    assert {:ok, _} = insert_workflow(repo, acme, host, "component", "legacy-component")
    assert {:ok, _} = insert_change_request(repo, acme, host, "lifecycle")

    legacy_workflows =
      rows(repo, "SELECT id::text, domain, resolution_key FROM finding_workflows")

    legacy_requests =
      rows(repo, "SELECT id::text, kind, after_value, reason FROM change_requests")

    assert violates(insert_workflow(repo, acme, host, "address", "192.0.2.5")) ==
             "finding_workflows_valid_domain"

    assert violates(insert_change_request(repo, acme, host, "adoption")) ==
             "change_requests_valid_kind"

    assert [@finding_workflows] = up(repo, @finding_workflows)
    assert {:ok, _} = insert_workflow(repo, acme, host, "address", "192.0.2.5")
    assert {:ok, _} = insert_change_request(repo, acme, host, "adoption")

    # Collectors that read device configuration become authoritative for
    # routing domains; other sources stay advisory.
    assert [@routing_domains] = up(repo, @routing_domains)

    assert rows(repo, """
           SELECT id::text, authoritative_routing_domains FROM sources ORDER BY kind
           """) == [[agent, true], [provider, false]]

    blue = insert_vrf(repo, acme, "blue")
    foreign_blue = insert_vrf(repo, other, "blue")
    assert {:ok, _} = insert_mapping(repo, acme, agent, "Lab", blue)

    # A key maps once per source regardless of case, and only to a VRF of
    # the source's organization.
    assert violates(insert_mapping(repo, acme, agent, "lab", "NULL")) ==
             "source_routing_domain_mappings_source_key_index"

    assert violates(insert_mapping(repo, acme, agent, "other", foreign_blue)) ==
             "source_routing_domain_mappings_tenant_vrf_fkey"

    assert {:ok, _} = insert_mapping(repo, acme, provider, "lab", "NULL")

    # Workflow keys widen past 255 characters for a source id and key.
    long_key = String.duplicate("k", 300)

    assert violates(insert_workflow(repo, acme, host, "address", long_key)) == :too_long
    assert [@wide_keys] = up(repo, @wide_keys)
    assert {:ok, _} = insert_workflow(repo, acme, host, "address", long_key)

    # A plan level is a real child length, once per family.
    assert [@plan_levels] = up(repo, @plan_levels)
    assert {:ok, _} = insert_plan_level(repo, acme, "ipv6", 56)
    assert {:ok, _} = insert_plan_level(repo, other, "ipv6", 56)
    assert {:ok, _} = insert_plan_level(repo, acme, "ipv4", 31)

    assert violates(insert_plan_level(repo, acme, "ipv6", 56)) ==
             "addressing_plan_levels_family_length_index"

    for {family, length} <- [{"ipv4", 32}, {"ipv4", 0}, {"ipv6", 128}, {"ipv6", 0}] do
      assert violates(insert_plan_level(repo, acme, family, length)) ==
               "addressing_plan_levels_valid_length"
    end

    # Narrowing the workflow keys again cannot silently truncate one.
    assert_raise Postgrex.Error, ~r/value too long/, fn ->
      Renga.ScratchMigrations.run(repo, :down, to: @wide_keys)
    end

    {:ok, _} = query(repo, "DELETE FROM finding_workflows WHERE length(resolution_key) > 255")
    Renga.ScratchMigrations.run(repo, :down, to: @strict)

    for table <- ~w(addressing_plan_levels source_routing_domain_mappings
                   interface_routing_domains interface_routing_domain_evidence
                   address_findings) do
      assert [[nil]] = rows(repo, "SELECT to_regclass('#{table}')::text")
    end

    # Rollback removes only the new domains/kinds and restores both old constraints.
    assert rows(repo, "SELECT id::text, domain, resolution_key FROM finding_workflows") ==
             legacy_workflows

    assert rows(repo, "SELECT id::text, kind, after_value, reason FROM change_requests") ==
             legacy_requests

    assert violates(insert_workflow(repo, acme, host, "address", "192.0.2.6")) ==
             "finding_workflows_valid_domain"

    assert violates(insert_change_request(repo, acme, host, "adoption")) ==
             "change_requests_valid_kind"

    assert violates(insert_workflow(repo, acme, host, "component", long_key)) == :too_long

    assert [] =
             rows(repo, """
             SELECT column_name FROM information_schema.columns
             WHERE (table_name = 'sources' AND column_name = 'authoritative_routing_domains')
                OR (table_name = 'prefixes' AND column_name = 'strict')
             """)
  end

  defp up(repo, version), do: Renga.ScratchMigrations.run(repo, :up, to: version)

  # The constraint a failed insert names, or `:too_long` for a value its
  # column cannot hold.
  defp violates({:error, %Postgrex.Error{postgres: %{code: :string_data_right_truncation}}}),
    do: :too_long

  defp violates({:error, %Postgrex.Error{postgres: %{constraint: constraint}}}), do: constraint

  defp insert_finding(repo, organization, interface, status, resolved_at) do
    query(repo, """
    INSERT INTO address_findings
      (id, organization_id, interface_id, kind, resolution_key, status, message,
       last_observed_at, resolved_at, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization}', '#{interface}', 'duplicate_address',
            '192.0.2.5', '#{status}', 'duplicate', now(), #{resolved_at}, now(), now())
    """)
  end

  defp insert_workflow(repo, organization, resource, domain, key) do
    query(repo, """
    INSERT INTO finding_workflows
      (id, organization_id, resource_id, domain, subject_id, kind, resolution_key,
       inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization}', '#{resource}', '#{domain}',
            gen_random_uuid(), 'duplicate_address', '#{key}', now(), now())
    """)
  end

  defp insert_change_request(repo, organization, resource, kind) do
    query(repo, """
    INSERT INTO change_requests
      (id, organization_id, resource_id, kind, after_value, reason, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization}', '#{resource}', '#{kind}',
            '{"value":"active"}', 'preserve this request', now(), now())
    """)
  end

  defp insert_mapping(repo, organization, source, key, "NULL"),
    do: do_insert_mapping(repo, organization, source, key, "NULL")

  defp insert_mapping(repo, organization, source, key, vrf),
    do: do_insert_mapping(repo, organization, source, key, "'#{vrf}'")

  defp do_insert_mapping(repo, organization, source, key, vrf) do
    query(repo, """
    INSERT INTO source_routing_domain_mappings
      (id, organization_id, source_id, source_local_key, vrf_id, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization}', '#{source}', '#{key}', #{vrf}, now(), now())
    """)
  end

  defp insert_plan_level(repo, organization, family, length) do
    query(repo, """
    INSERT INTO addressing_plan_levels
      (id, organization_id, family, prefix_length, name, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{organization}', '#{family}', #{length}, 'level', now(), now())
    """)
  end

  defp insert_vrf(repo, organization, name) do
    id = Ecto.UUID.generate()
    resource = insert_resource(repo, organization, "vrf", name)

    {:ok, _} =
      query(repo, """
      INSERT INTO vrfs (id, organization_id, resource_id, name, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization}', '#{resource}', '#{name}', now(), now())
      """)

    id
  end

  defp insert_source(repo, organization, kind) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      query(repo, """
      INSERT INTO sources (id, organization_id, kind, name, inserted_at, updated_at)
      VALUES ('#{id}', '#{organization}', '#{kind}', '#{kind}', now(), now())
      """)

    id
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
