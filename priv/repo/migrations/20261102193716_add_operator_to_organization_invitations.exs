defmodule Renga.Repo.Migrations.AddOperatorToOrganizationInvitations do
  use Ecto.Migration

  # RFD 22: an operator can invite an organization's owner. Such an
  # invitation has no inviting user; it names the operator instead, and the
  # token when the API made it, so revoking that token also stops it.
  def change do
    alter table(:organization_invitations) do
      add :invited_by_operator, :text

      add :invited_by_operator_token_id,
          references(:operator_tokens, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
