defmodule Renga.Enrollment.EnrollmentReplay do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_replays" do
    field :kind, :string
    field :value_hash, :binary
    field :expires_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :verifier_configuration, Renga.Enrollment.VerifierConfiguration
    belongs_to :agent_credential, Renga.Enrollment.AgentCredential
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:kind, :value_hash, :expires_at])
      |> validate_required([:organization_id, :kind, :value_hash, :expires_at])
      |> validate_inclusion(:kind, ~w(oidc_digest oidc_jti runtime_nonce))
      |> validate_length(:value_hash, is: 32, count: :bytes)
      |> check_constraint(:kind, name: :enrollment_replays_owner_and_hash)
      |> unique_constraint(:value_hash, name: :enrollment_replays_verifier_index)
      |> unique_constraint(:value_hash, name: :enrollment_replays_credential_index)
end
