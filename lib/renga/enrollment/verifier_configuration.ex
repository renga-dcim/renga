defmodule Renga.Enrollment.VerifierConfiguration do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  schema "verifier_configurations" do
    field :name, :string
    field :version, :integer
    field :kind, :string
    field :subject_cardinality, :string
    field :configuration, :map
    field :enabled, :boolean, default: true
    field :disabled_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :created_by_membership, Renga.Accounts.OrganizationMembership
    timestamps(updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:name, :version, :kind, :subject_cardinality, :configuration])
      |> validate_required([
        :organization_id,
        :created_by_membership_id,
        :name,
        :version,
        :kind,
        :subject_cardinality,
        :configuration
      ])
      |> validate_length(:name, max: 255)
      |> validate_inclusion(:subject_cardinality, ~w(singleton group))
      |> validate_inclusion(:kind, ~w(manual oidc))
      |> validate_number(:version, greater_than: 0)
      |> validate_oidc_configuration()
      |> unique_constraint([:organization_id, :name, :version])

  defp validate_oidc_configuration(changeset) do
    if get_field(changeset, :kind) == "oidc" and
         Renga.Enrollment.OIDC.validate_configuration(get_field(changeset, :configuration)) != :ok do
      add_error(changeset, :configuration, "is not a valid immutable OIDC verifier configuration")
    else
      changeset
    end
  end

  def disable_changeset(row, now),
    do:
      row
      |> change(enabled: false, disabled_at: now)
      |> check_constraint(:enabled, name: :verifier_configurations_enabled_state)
end
