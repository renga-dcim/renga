defmodule Renga.Repo.Migrations.AllowInternalReconciliationProvenance do
  use Ecto.Migration

  def change do
    # Operator/maintenance retries can process evidence without an intake identity.
    # Null is provenance, never fabricated installation authority.
    alter table(:reconciliation_work) do
      modify :original_key_id, :binary_id, null: true, from: {:binary_id, null: false}
      modify :installation_agent_id, :binary_id, null: true, from: {:binary_id, null: false}
      modify :installation_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :origin, :string, null: false, default: "intake"
    end

    create constraint(:reconciliation_work, :reconciliation_work_provenance,
             check:
               "(origin = 'intake' AND original_key_id IS NOT NULL AND " <>
                 "installation_agent_id IS NOT NULL AND installation_id IS NOT NULL) OR " <>
                 "(origin = 'maintenance' AND installation_agent_id IS NULL AND installation_id IS NULL)"
           )
  end
end
