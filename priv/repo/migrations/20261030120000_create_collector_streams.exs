defmodule Renga.Repo.Migrations.CreateCollectorStreams do
  use Ecto.Migration

  # RFD 11 phase 1: an installation keeps its host source and may run
  # collector modules, each reporting through its own server-resolved source
  # keyed by the installation's agent and a locally configured collector ID.
  # A scoped report is stored once as the raw observation and split into one
  # derived observation per resource, so per-resource reconciliation,
  # provenance, and clocks work as they do for host reports.
  def change do
    alter table(:sources) do
      # NO ACTION rather than RESTRICT so organization teardown, which
      # cascades to agents and sources in one statement, is checked only once
      # both are gone.
      add :agent_id,
          references(:agents,
            with: [organization_id: :organization_id],
            on_delete: :nothing,
            type: :binary_id,
            name: :sources_tenant_agent_fkey
          )

      add :collector_id, :string
    end

    create unique_index(:sources, [:organization_id, :agent_id, :collector_id],
             where: "collector_id IS NOT NULL",
             name: :sources_agent_collector_index
           )

    create constraint(:sources, :sources_collector_stream,
             check: """
             (collector_id IS NULL AND agent_id IS NULL)
             OR
             (collector_id IS NOT NULL AND agent_id IS NOT NULL
              AND kind IN ('switch_poller', 'vm_provider'))
             """
           )

    alter table(:observations) do
      add :parent_observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :observations_parent_fkey
          )

      add :resource_index, :integer
    end

    create unique_index(:observations, [:parent_observation_id, :resource_index],
             where: "parent_observation_id IS NOT NULL",
             name: :observations_parent_resource_index
           )

    create constraint(:observations, :observations_derived_resource,
             check:
               "(parent_observation_id IS NULL) = (resource_index IS NULL) AND " <>
                 "(resource_index IS NULL OR resource_index >= 0)"
           )

    create table(:collector_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_targets_tenant_source_fkey
          ),
          null: false

      # A switch poller's target address or a hypervisor's stable ID.
      add :key, :string, null: false
      add :status, :string, null: false
      add :error, :string
      add :last_reported_at, :"timestamp(3)", null: false
      add :last_reachable_at, :"timestamp(3)"

      add :last_observation_id,
          references(:observations,
            with: [organization_id: :organization_id],
            on_delete: :nilify_all,
            type: :binary_id,
            name: :collector_targets_tenant_observation_fkey
          )

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:collector_targets, [:organization_id, :source_id, :key])
    create unique_index(:collector_targets, [:id, :organization_id, :source_id])

    create constraint(:collector_targets, :collector_targets_status,
             check: "status IN ('reachable', 'unreachable')"
           )

    create table(:collector_target_resources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, :binary_id, null: false

      add :target_id,
          references(:collector_targets,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_target_resources_tenant_target_fkey
          ),
          null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_target_resources_tenant_resource_fkey
          ),
          null: false

      add :first_reported_at, :"timestamp(3)", null: false
      add :last_reported_at, :"timestamp(3)", null: false
      # Set when a complete report for the target no longer contained the
      # resource. A later report clears it; an older replay cannot.
      add :withdrawn_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:collector_target_resources, [:organization_id, :target_id, :resource_id])
    create index(:collector_target_resources, [:organization_id, :resource_id])
  end
end
