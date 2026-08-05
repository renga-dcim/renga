defmodule Renga.Inventory.ResourceOverride do
  @moduledoc """
  Field-level manual value that takes precedence over observed inventory data.

  Overrides are scoped to one resource and one field so reconciliation can
  preserve operator intent without freezing unrelated fields on the resource.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_overrides" do
    field :field, :string
    field :value, :map
    field :reason, :string

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :created_by_user, User

    timestamps()
  end

  def changeset(resource_override, attrs) do
    resource_override
    |> cast(attrs, [:field, :value, :reason])
    |> update_change(:field, &trim_string/1)
    |> update_change(:reason, &trim_string/1)
    |> validate_required([:organization_id, :resource_id, :field, :value])
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :resource_overrides_organization_resource_fkey)
    |> assoc_constraint(:created_by_user)
    |> unique_constraint([:organization_id, :resource_id, :field])
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
