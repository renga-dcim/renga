defmodule Renga.Repo.Migrations.CreateInstallationKeys do
  use Ecto.Migration

  # RFD 13 phase 1: each installation presents an Ed25519 public key on
  # check-in. The first key is pending until an owner or admin approves it
  # by fingerprint; a different key replaces it and returns the installation
  # to pending. Replaced keys stay as history.
  def change do
    create table(:installation_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :agent_id,
          references(:agents,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :installation_keys_organization_agent_fkey
          ),
          null: false

      add :algorithm, :string, null: false
      add :public_key, :binary, null: false
      add :fingerprint, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :first_presented_at, :"timestamp(3)", null: false
      add :last_presented_at, :"timestamp(3)", null: false
      add :approved_at, :"timestamp(3)"
      add :approved_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :replaced_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:installation_keys, [:id, :organization_id])

    # One current key per installation.
    create unique_index(:installation_keys, [:organization_id, :agent_id],
             where: "status IN ('pending', 'approved')",
             name: :installation_keys_current_index
           )

    create index(:installation_keys, [:organization_id, :agent_id, :inserted_at])

    create constraint(:installation_keys, :installation_keys_valid,
             check: """
             algorithm = 'ed25519'
             AND octet_length(public_key) = 32
             AND status IN ('pending', 'approved', 'replaced')
             AND (status = 'approved') = (approved_at IS NOT NULL AND replaced_at IS NULL)
             AND (status = 'replaced') = (replaced_at IS NOT NULL)
             """
           )

    # Collector findings: what Renga noticed about an installation, filed on
    # the resource the installation reports so it reaches the Inbox.
    create table(:collector_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_findings_organization_resource_fkey
          ),
          null: false

      add :agent_id,
          references(:agents,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_findings_organization_agent_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :last_observed_at, :"timestamp(3)", null: false
      add :resolved_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:collector_findings, [:organization_id, :resource_id, :agent_id, :kind],
             where: "status = 'open'",
             name: :collector_findings_open_index
           )

    create index(:collector_findings, [:organization_id, :agent_id, :status])
    create index(:collector_findings, [:organization_id, :status, :kind])

    create constraint(:collector_findings, :collector_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN ('installation_key_changed')
             """
           )

    # Rolling back drops collector workflows (assignments, snoozes,
    # exceptions) first, as the address domain's rollback does, or the
    # narrower constraint would refuse them.
    execute(
      fn ->
        repo().query!(
          workflow_domains(~w(component hardware_match placement topology address collector))
        )
      end,
      fn ->
        repo().query!("DELETE FROM finding_workflows WHERE domain = 'collector'")
        repo().query!(workflow_domains(~w(component hardware_match placement topology address)))
      end
    )
  end

  defp workflow_domains(domains) do
    """
    ALTER TABLE finding_workflows
      DROP CONSTRAINT finding_workflows_valid_domain,
      ADD CONSTRAINT finding_workflows_valid_domain
        CHECK (domain IN (#{Enum.map_join(domains, ", ", &"'#{&1}'")}))
    """
  end
end
