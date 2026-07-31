defmodule Renga.Accounts.OrganizationMembership do
  @moduledoc """
  Connects the generated authenticated user model to an organization.

  Memberships are where user identity becomes tenant authorization. Roles are
  intentionally simple for the MVP, but the row is the future place to hang
  tenant-specific RBAC and audit metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @roles ~w(owner admin member viewer)
  @statuses ~w(active disabled)
  @timestamps_opts [type: :utc_datetime]

  schema "organization_memberships" do
    field :role, :string, default: "member"
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :role, :status, :metadata])
    |> validate_required([:organization_id, :user_id, :role, :status])
    |> validate_uuid(:user_id)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:user)
    |> unique_constraint([:organization_id, :user_id])
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
    end)
  end
end
