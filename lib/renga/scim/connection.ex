defmodule Renga.Scim.Connection do
  @moduledoc """
  An organization's SCIM connection (RFD 16, "Connections"): the identity
  provider whose identities its directory entries describe, the ID token
  claim the provider sends as each user's `externalId`, and the role every
  active provisioned user gets by default. The organization, provider, and
  correlation claim never change; a different provider or claim needs a
  replacement connection.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @roles ~w(owner admin member viewer)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scim_connections" do
    field :correlation_claim, :string, default: "sub"
    field :default_role, :string
    field :disabled_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string
    belongs_to :created_by_user, Renga.Accounts.User
    has_many :tokens, Renga.Scim.Token

    timestamps(type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []})
  end

  def create_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:provider_id, :correlation_claim, :default_role])
    |> validate_required([:organization_id, :provider_id, :correlation_claim])
    |> validate_default_role()
    |> unique_constraint(:organization_id,
      name: :scim_connections_one_enabled,
      message: "already has a SCIM connection"
    )
  end

  def default_role_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:default_role])
    |> validate_default_role()
  end

  def enabled?(%__MODULE__{disabled_at: disabled_at}), do: is_nil(disabled_at)

  # A blank choice means no default role: only mapped groups grant access.
  defp validate_default_role(changeset) do
    changeset
    |> update_change(:default_role, &if(&1 == "", do: nil, else: &1))
    |> validate_inclusion(:default_role, @roles)
  end
end
