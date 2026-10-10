defmodule Renga.Repo.Migrations.CreateRoutingDomainClaims do
  @moduledoc """
  RFD 4, Phase 6: routing-domain claims.

  A collector may say which routing domain an interface is in, as a
  source-local key (and optionally a route distinguisher). Each claim is
  immutable, observation-linked evidence that a newer report from the same
  source makes stale, including a report that withdraws the claim. A source's `authoritative_routing_domains` capability
  says whether its claims are trusted enough to call a managed assignment
  wrong; collectors that read a device's own configuration are by default.

  Source-local keys map to managed VRFs explicitly per source, or by route
  distinguisher or VRF name. `interface_routing_domains` is the resolved
  current claim per interface; an interface without a row has no claim and
  is in the global table.
  """
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :authoritative_routing_domains, :boolean, null: false, default: false
    end

    execute(
      "UPDATE sources SET authoritative_routing_domains = true WHERE kind IN ('host_agent', 'switch_poller')",
      ""
    )

    create table(:interface_routing_domain_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_routing_domain_evidence_tenant_interface_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_routing_domain_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_routing_domain_evidence_tenant_observation_fkey
          ),
          null: false

      # Null records an explicit withdrawal: the source reported the
      # interface in no routing domain. It is never active, but it orders
      # later replays of older claims behind it.
      add :source_local_key, :string
      add :route_distinguisher, :string
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false
      add :stale_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create constraint(
             :interface_routing_domain_evidence,
             :interface_routing_domain_evidence_withdrawal_inactive,
             check: "source_local_key IS NOT NULL OR stale_at IS NOT NULL"
           )

    create unique_index(
             :interface_routing_domain_evidence,
             [:organization_id, :observation_id, :interface_id],
             name: :interface_routing_domain_evidence_observation_link_index
           )

    create index(:interface_routing_domain_evidence, [:organization_id, :interface_id],
             where: "stale_at IS NULL",
             name: :interface_routing_domain_evidence_active_index
           )

    create table(:source_routing_domain_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :source_routing_domain_mappings_tenant_source_fkey
          ),
          null: false

      add :source_local_key, :string, null: false

      # Null maps the key to the global table.
      add :vrf_id,
          references(:vrfs,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :source_routing_domain_mappings_tenant_vrf_fkey
          )

      add :created_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :source_routing_domain_mappings,
             [:organization_id, :source_id, "lower(source_local_key)"],
             name: :source_routing_domain_mappings_source_key_index
           )

    create table(:interface_routing_domains, primary_key: false) do
      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_routing_domains_tenant_interface_fkey
          ),
          primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :evidence_id,
          references(:interface_routing_domain_evidence,
            on_delete: :delete_all,
            type: :binary_id
          ),
          null: false

      add :source_id, :binary_id, null: false
      add :source_local_key, :string, null: false
      add :route_distinguisher, :string
      add :authoritative, :boolean, null: false
      add :resolution, :string, null: false

      # A projection row is recomputed from evidence, so one naming a deleted
      # VRF simply goes until the next refresh rebuilds it.
      add :vrf_id,
          references(:vrfs,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_routing_domains_tenant_vrf_fkey
          )

      add :observed_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)")
    end

    create index(:interface_routing_domains, [:organization_id, :resolution])

    create constraint(:interface_routing_domains, :interface_routing_domains_valid_resolution,
             check:
               "resolution IN ('mapping', 'route_distinguisher', 'name', 'default', 'unmapped') " <>
                 "AND (resolution <> 'unmapped' OR vrf_id IS NULL)"
           )
  end
end
