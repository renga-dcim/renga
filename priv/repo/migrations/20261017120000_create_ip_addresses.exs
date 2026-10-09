defmodule Renga.Repo.Migrations.CreateIpAddresses do
  @moduledoc """
  RFD 4, Phase 3: managed addresses become `ip_address` records.

  The shipped `managed_addresses` table evolves in place rather than gaining
  a parallel one. Each managed address gets a resource envelope (which owns
  lifecycle, so release can retire it instead of deleting its history), a
  routing namespace (`vrf_id`, null for the global table), and orthogonal
  allocation state, management mode, and role.

  The address now keeps its intended prefix length. Identity is still the
  host: one managed address per namespace and host value, so `192.0.2.10/24`
  and `192.0.2.10/32` are the same address. The interface an address was
  adopted from becomes an assignment row, which later phases let operators
  add, share, and remove.

  Existing rows move to the global table as allocated, ordinary addresses,
  assigned to the interface they remember. Their intended mask is recovered
  from the observed address on that interface when one is still present and
  otherwise stays at the host length.
  """
  use Ecto.Migration

  @resource_revision_lock_key 1_380_271_687

  # The revision snapshot `Renga.Inventory.ResourceStore` writes, in SQL.
  @snapshot """
  jsonb_build_object(
    'id', id, 'kind', kind, 'name', name, 'display_name', display_name,
    'lifecycle_state', lifecycle_state, 'spec', spec, 'generation', generation,
    'resource_version', resource_version, 'labels', labels,
    'annotations', annotations, 'deletion_requested_at', deletion_requested_at
  )
  """

  def up do
    rename table(:managed_addresses), to: table(:ip_addresses)

    execute "ALTER TABLE ip_addresses RENAME CONSTRAINT managed_addresses_pkey TO ip_addresses_pkey"

    execute """
    ALTER TABLE ip_addresses
      RENAME CONSTRAINT managed_addresses_organization_id_fkey TO ip_addresses_organization_id_fkey
    """

    execute """
    ALTER TABLE ip_addresses
      RENAME CONSTRAINT managed_addresses_adopted_by_id_fkey TO ip_addresses_adopted_by_id_fkey
    """

    drop index(:ip_addresses, [:organization_id, :address],
           name: :managed_addresses_organization_address_index
         )

    drop constraint(:ip_addresses, :managed_addresses_host_address)

    alter table(:ip_addresses) do
      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :ip_addresses_organization_resource_fkey
          )

      add :vrf_id,
          references(:vrfs,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :ip_addresses_tenant_vrf_fkey
          )

      add :allocation_state, :string, null: false, default: "allocated"
      add :management_mode, :string
      add :role, :string, null: false, default: "ordinary"
      add :dns_name, :string
      add :metadata, :map, null: false, default: %{}
    end

    create unique_index(:ip_addresses, [:id, :organization_id])

    create table(:ip_address_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :ip_address_id,
          references(:ip_addresses,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :ip_address_assignments_tenant_ip_address_fkey
          ),
          null: false

      # An assignment is current intent about one interface; it goes with
      # the interface, while the managed address itself stays.
      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :ip_address_assignments_tenant_interface_fkey
          ),
          null: false

      add :assigned_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:ip_address_assignments, [:ip_address_id, :interface_id],
             name: :ip_address_assignments_address_interface_index
           )

    create index(:ip_address_assignments, [:organization_id, :interface_id])

    flush()

    migrate_rows()

    alter table(:ip_addresses) do
      remove :interface_id
      modify :resource_id, :binary_id, null: false
    end

    create unique_index(:ip_addresses, [:organization_id, :resource_id])

    # One managed address per namespace and host, whatever its intended mask.
    create unique_index(:ip_addresses, [:organization_id, :vrf_id, "(host(address)::inet)"],
             name: :ip_addresses_namespace_host_index,
             nulls_distinct: false
           )

    create constraint(:ip_addresses, :ip_addresses_valid_allocation_state,
             check: "allocation_state IN ('allocated', 'reserved')"
           )

    create constraint(:ip_addresses, :ip_addresses_valid_management_mode,
             check: "management_mode IS NULL OR management_mode IN ('static', 'dhcp', 'slaac')"
           )

    create constraint(:ip_addresses, :ip_addresses_valid_role,
             check:
               "role IN ('ordinary', 'loopback', 'secondary', 'vip', 'anycast', 'vrrp', 'hsrp', 'glbp', 'carp')"
           )
  end

  def down do
    drop constraint(:ip_addresses, :ip_addresses_valid_role)
    drop constraint(:ip_addresses, :ip_addresses_valid_management_mode)
    drop constraint(:ip_addresses, :ip_addresses_valid_allocation_state)

    drop index(:ip_addresses, [:organization_id, :vrf_id],
           name: :ip_addresses_namespace_host_index
         )

    drop index(:ip_addresses, [:organization_id, :resource_id])

    alter table(:ip_addresses) do
      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:interface_id]},
            type: :binary_id,
            name: :managed_addresses_tenant_interface_fkey
          )
    end

    flush()

    # The shipped table held current, global, host-length intent with one
    # remembered interface; retired and VRF addresses have no place in it.
    repo().query!("""
    DELETE FROM ip_addresses
    USING resources
    WHERE resources.id = ip_addresses.resource_id
      AND (resources.lifecycle_state <> 'active' OR ip_addresses.vrf_id IS NOT NULL)
    """)

    repo().query!("""
    UPDATE ip_addresses
    SET address = host(address)::inet,
        interface_id = (
          SELECT interface_id FROM ip_address_assignments
          WHERE ip_address_assignments.ip_address_id = ip_addresses.id
          ORDER BY inserted_at LIMIT 1
        )
    """)

    drop table(:ip_address_assignments)
    drop index(:ip_addresses, [:id, :organization_id])

    alter table(:ip_addresses) do
      remove :resource_id
      remove :vrf_id
      remove :allocation_state
      remove :management_mode
      remove :role
      remove :dns_name
      remove :metadata
    end

    flush()

    # Only once the rows no longer reference them, or the cascade would take
    # the addresses with their envelopes.
    repo().query!("DELETE FROM resources WHERE kind = 'ip_address'")

    rename table(:ip_addresses), to: table(:managed_addresses)

    execute "ALTER TABLE managed_addresses RENAME CONSTRAINT ip_addresses_pkey TO managed_addresses_pkey"

    execute """
    ALTER TABLE managed_addresses
      RENAME CONSTRAINT ip_addresses_organization_id_fkey TO managed_addresses_organization_id_fkey
    """

    execute """
    ALTER TABLE managed_addresses
      RENAME CONSTRAINT ip_addresses_adopted_by_id_fkey TO managed_addresses_adopted_by_id_fkey
    """

    create unique_index(:managed_addresses, [:organization_id, :address],
             name: :managed_addresses_organization_address_index
           )

    create constraint(:managed_addresses, :managed_addresses_host_address,
             check: "masklen(address) = CASE family(address) WHEN 4 THEN 32 ELSE 128 END"
           )
  end

  defp migrate_rows do
    repo().query!("SELECT pg_advisory_xact_lock($1)", [@resource_revision_lock_key])

    # Recover the intended mask from the remembered interface's current
    # observation of the same host, when there is one.
    repo().query!("""
    UPDATE ip_addresses
    SET address = observed.address
    FROM (
      SELECT DISTINCT ON (managed.id) managed.id, addresses.address
      FROM ip_addresses AS managed
      JOIN addresses
        ON addresses.organization_id = managed.organization_id
       AND addresses.interface_id = managed.interface_id
       AND host(addresses.address)::inet = host(managed.address)::inet
       AND (addresses.metadata->'present') IS DISTINCT FROM 'false'::jsonb
      ORDER BY managed.id, addresses.updated_at DESC
    ) AS observed
    WHERE ip_addresses.id = observed.id
    """)

    %{rows: rows} =
      repo().query!(
        "SELECT id, organization_id, host(address), interface_id, adopted_by_id FROM ip_addresses"
      )

    for [id, organization_id, host, interface_id, adopted_by_id] <- rows do
      resource_id = Ecto.UUID.bingenerate()

      repo().query!(
        """
        INSERT INTO resources
          (id, organization_id, kind, name, display_name, lifecycle_state, resource_version,
           inserted_at, updated_at)
        VALUES ($1, $2, 'ip_address', $3, $4, 'active', nextval('resource_revision_sequence'),
                now(), now())
        """,
        [resource_id, organization_id, "ip-address-" <> Ecto.UUID.load!(resource_id), host]
      )

      repo().query!(
        """
        INSERT INTO resource_revisions
          (id, organization_id, resource_id, revision, action, generation, snapshot, inserted_at)
        SELECT gen_random_uuid(), organization_id, id, resource_version, 'created', generation,
               #{@snapshot}, now()
        FROM resources WHERE id = $1
        """,
        [resource_id]
      )

      repo().query!("UPDATE ip_addresses SET resource_id = $1 WHERE id = $2", [resource_id, id])

      if interface_id do
        repo().query!(
          """
          INSERT INTO ip_address_assignments
            (id, organization_id, ip_address_id, interface_id, assigned_by_id, inserted_at,
             updated_at)
          VALUES (gen_random_uuid(), $1, $2, $3, $4, now(), now())
          """,
          [organization_id, id, interface_id, adopted_by_id]
        )
      end
    end
  end
end
