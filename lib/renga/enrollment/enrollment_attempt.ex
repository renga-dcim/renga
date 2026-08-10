defmodule Renga.Enrollment.EnrollmentAttempt do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_attempts" do
    field :normalized_envelope, :map
    field :evidence_digest, :binary
    field :status, :string
    field :reason, :string
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_challenge, Renga.Enrollment.EnrollmentChallenge
    belongs_to :enrollment_policy, Renga.Enrollment.EnrollmentPolicy
    belongs_to :verifier_configuration, Renga.Enrollment.VerifierConfiguration
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:normalized_envelope, :evidence_digest, :status, :reason])
      |> validate_required([
        :organization_id,
        :enrollment_challenge_id,
        :enrollment_policy_id,
        :verifier_configuration_id,
        :evidence_digest,
        :status
      ])
      |> validate_inclusion(:status, ~w(received verified rejected unavailable))
      |> validate_length(:evidence_digest, is: 32)
      |> check_constraint(:status, name: :enrollment_attempts_valid)
end
