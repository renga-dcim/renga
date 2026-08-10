defmodule Renga.Enrollment.EnrollmentIdentity do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_identities" do
    field :issuer, :string
    field :subject, :string
    field :subject_cardinality, :string
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :verifier_configuration, Renga.Enrollment.VerifierConfiguration
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:issuer, :subject, :subject_cardinality])
      |> validate_required([
        :organization_id,
        :verifier_configuration_id,
        :issuer,
        :subject,
        :subject_cardinality
      ])
      |> validate_inclusion(:subject_cardinality, ~w(singleton group))
      |> unique_constraint([:organization_id, :verifier_configuration_id, :issuer, :subject],
        name: :enrollment_identities_namespace_index
      )
end
