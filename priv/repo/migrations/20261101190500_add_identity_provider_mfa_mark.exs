defmodule Renga.Repo.Migrations.AddIdentityProviderMfaMark do
  use Ecto.Migration

  # RFD 19, "MFA requirement": the _enforces MFA_ mark, and the `amr`
  # combinations the provider's configuration approves as independent
  # factors, each a sorted, "+"-joined set of RFC 8176 values such as
  # "otp+pwd". GitHub's OAuth API says nothing about how someone signed in,
  # so a github provider can never be marked.
  def change do
    alter table(:identity_providers) do
      add :enforces_mfa, :boolean, null: false, default: false
      add :mfa_amr_combinations, {:array, :string}, null: false, default: []
    end

    create constraint(:identity_providers, :github_never_enforces_mfa,
             check: "kind <> 'github' OR NOT enforces_mfa"
           )
  end
end
