defmodule Renga.Repo.Migrations.CreateTargetBindings do
  use Ecto.Migration

  # RFD 13 phase 1, "Trusted privileged targets": an owner or admin binds a
  # resource to one installation and its approved key. Privileged jobs
  # capture the binding and its version when created, and are leased only
  # through a request signed with that key.
  def change do
    create table(:target_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :target_bindings_organization_resource_fkey
          ),
          null: false

      add :agent_id,
          references(:agents,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :target_bindings_organization_agent_fkey
          ),
          null: false

      add :installation_key_id,
          references(:installation_keys,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :target_bindings_organization_key_fkey
          ),
          null: false

      add :version, :integer, null: false
      add :status, :string, null: false, default: "active"
      add :approved_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :approved_at, :"timestamp(3)", null: false
      add :revoked_at, :"timestamp(3)"
      add :revoked_reason, :string
      add :revoked_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:target_bindings, [:id, :organization_id])
    create unique_index(:target_bindings, [:organization_id, :resource_id, :version])

    create unique_index(:target_bindings, [:organization_id, :resource_id],
             where: "status = 'active'",
             name: :target_bindings_active_index
           )

    create index(:target_bindings, [:organization_id, :installation_key_id])
    create index(:target_bindings, [:organization_id, :agent_id])

    create constraint(:target_bindings, :target_bindings_valid,
             check: """
             version > 0
             AND status IN ('active', 'revoked')
             AND (status = 'revoked') = (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL)
             AND (revoked_reason IS NULL OR revoked_reason IN ('replaced', 'revoked', 'key_replaced'))
             """
           )

    alter table(:jobs) do
      add :target_binding_id,
          references(:target_bindings,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:target_binding_id]},
            type: :binary_id,
            name: :jobs_organization_target_binding_fkey
          )

      add :target_binding_version, :integer

      # The current lease offer for a privileged job: the agent signs over the
      # token and nonce to claim it before the offer expires.
      add :offer_token_hash, :binary
      add :offer_nonce, :string
      add :offer_expires_at, :"timestamp(3)"
    end

    create constraint(:jobs, :jobs_privileged_binding,
             check: """
             (risk_class = 'observe') = (target_binding_version IS NULL)
             AND (offer_token_hash IS NULL) = (offer_nonce IS NULL)
             AND (offer_token_hash IS NULL) = (offer_expires_at IS NULL)
             """
           )
  end
end
