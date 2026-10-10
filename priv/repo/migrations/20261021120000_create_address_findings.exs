defmodule Renga.Repo.Migrations.CreateAddressFindings do
  @moduledoc """
  RFD 4, Phase 5: address findings, the `address` Inbox domain.

  Like topology findings, each belongs to an interface (its resource is the
  interface's resource) and is identified by kind and a resolution key, so
  reconciliation can open, refresh, and resolve it as observed state
  converges. A resolved finding stays as history; a recurrence opens a new
  row, and the workflow keyed by the same identity follows it.
  """
  use Ecto.Migration

  def change do
    create table(:address_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :address_findings_tenant_interface_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :resolution_key, :text, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :last_observed_at, :"timestamp(3)", null: false
      add :resolved_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :address_findings,
             [:organization_id, :interface_id, :kind, :resolution_key],
             where: "status = 'open'",
             name: :address_findings_open_resolution_index
           )

    create index(:address_findings, [:organization_id, :status, :kind])
    create index(:address_findings, [:organization_id, :interface_id])

    create constraint(:address_findings, :address_findings_valid_status,
             check: "status IN ('open', 'resolved')"
           )

    create constraint(:address_findings, :address_findings_resolution_state,
             check:
               "(status = 'open' AND resolved_at IS NULL) OR (status = 'resolved' AND resolved_at IS NOT NULL)"
           )
  end
end
