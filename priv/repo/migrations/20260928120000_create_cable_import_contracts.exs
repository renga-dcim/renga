defmodule Renga.Repo.Migrations.CreateCableImportContracts do
  use Ecto.Migration

  # An import claim is authoritative cabling, so a source needs an explicit
  # manager-granted contract: tenant membership of a source is provenance, not
  # trust. Contracts are revocable and only gate new imports; retained
  # assertions and the reconciled cable stay valid after revocation.
  def change do
    create table(:cable_import_contracts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_import_contracts_tenant_source_fkey
          ),
          null: false

      # Attribution only nullifies so a deleted manager cannot rewrite or block
      # the contract's provenance.
      add :granted_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :granted_at, :"timestamp(3)", null: false
      add :revoked_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :revoked_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:cable_import_contracts, [:organization_id, :source_id],
             name: :cable_import_contracts_source_index
           )

    create unique_index(:cable_import_contracts, [:id, :organization_id])
  end
end
