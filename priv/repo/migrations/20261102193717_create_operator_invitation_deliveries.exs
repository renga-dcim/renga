defmodule Renga.Repo.Migrations.CreateOperatorInvitationDeliveries do
  use Ecto.Migration

  # RFD 22, "Writes": an owner invitation and its completed idempotent
  # response commit with an encrypted delivery intent before email is sent.
  # A worker can then recover an interrupted or failed delivery without making
  # another invitation or exposing its secret.
  def change do
    create table(:operator_invitation_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :invitation_id,
          references(:organization_invitations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :url_ciphertext, :binary, null: false
      add :url_key_id, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :available_at, :"timestamp(3)", null: false
      add :lease_id, :binary_id
      add :lease_expires_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:operator_invitation_deliveries, [:invitation_id])

    create index(:operator_invitation_deliveries, [:available_at, :lease_expires_at],
             name: :operator_invitation_deliveries_available_index
           )

    create constraint(:operator_invitation_deliveries, :operator_invitation_deliveries_attempts,
             check: "attempts >= 0"
           )

    create constraint(:operator_invitation_deliveries, :operator_invitation_deliveries_lease,
             check:
               "(lease_id IS NULL AND lease_expires_at IS NULL) OR " <>
                 "(lease_id IS NOT NULL AND lease_expires_at IS NOT NULL)"
           )
  end
end
