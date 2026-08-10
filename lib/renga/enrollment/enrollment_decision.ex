defmodule Renga.Enrollment.EnrollmentDecision do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_decisions" do
    field :outcome, :string
    field :reason, :string
    field :assurance, :string
    field :provenance, :map
    field :condition_ids, {:array, :string}, default: []
    field :assignments, :map, default: %{}
    field :grants, {:array, :string}, default: []
    field :verifier_key_thumbprint, :binary
    field :safe_public_jwk, :map
    field :evaluated_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_attempt, Renga.Enrollment.EnrollmentAttempt
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :outcome,
        :reason,
        :assurance,
        :provenance,
        :condition_ids,
        :assignments,
        :grants,
        :verifier_key_thumbprint,
        :safe_public_jwk,
        :evaluated_at
      ])
      |> validate_required([
        :organization_id,
        :enrollment_attempt_id,
        :outcome,
        :reason,
        :assurance,
        :provenance,
        :verifier_key_thumbprint,
        :safe_public_jwk,
        :evaluated_at
      ])
      |> validate_inclusion(:outcome, ~w(allow deny))
      |> validate_length(:verifier_key_thumbprint, is: 32, count: :bytes)
      |> check_constraint(:safe_public_jwk, name: :enrollment_decisions_valid)
end
