defmodule Renga.Repo.Migrations.AddEnrollmentCleanupIndexes do
  use Ecto.Migration

  def change do
    create index(:enrollment_challenges, [:enrollment_profile_id, :status, :expires_at],
             name: :enrollment_challenges_profile_open_expiry_index,
             where: "status = 'open' AND submission_digest IS NULL"
           )

    create index(:enrollment_challenges, [:expires_at],
             name: :enrollment_challenges_global_open_expiry_index,
             where: "status = 'open' AND submission_digest IS NULL"
           )

    create constraint(:enrollment_identities, :enrollment_identities_identity_byte_lengths,
             check: "octet_length(issuer) <= 255 AND octet_length(subject) <= 255"
           )
  end
end
