defmodule Renga.Repo.Migrations.AddSessionMfaEvidence do
  use Ecto.Migration

  # RFD 19, "MFA requirement": what a session's sign-in proved, kept as
  # evidence rather than an account-wide flag so each organization evaluates
  # it for itself. `second_factor_at` is when Renga's own second factor
  # passed for this session. A provider sign-in keeps the provider, its
  # owning organization (null for a deployment provider), and the ID token's
  # `amr` claim (null when the token had none). The organization ID has no
  # foreign key: nulling it would turn an organization provider's evidence
  # into a deployment provider's.
  def change do
    alter table(:users_tokens) do
      add :second_factor_at, :"timestamp(3)"

      add :provider_id,
          references(:identity_providers, type: :string, on_delete: :nilify_all)

      add :provider_organization_id, :binary_id
      add :provider_amr, {:array, :string}
    end
  end
end
