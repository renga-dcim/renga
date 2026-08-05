defmodule Renga.Inventory.ResourceRelationship do
  @moduledoc """
  Source-neutral cross-domain relationship between resource envelopes.

  Typed relationships such as bond membership stay in their domain tables.
  This table is reserved for links such as a VM being hosted on a server where
  no narrower projection owns the relationship.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(hosted_on connected_to depends_on backed_by member_of)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_relationships" do
    field :kind, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :source_resource, Resource
    belongs_to :target_resource, Resource

    timestamps()
  end

  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, [:kind, :metadata])
    |> validate_required([:organization_id, :source_resource_id, :target_resource_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_distinct_resources()
    |> check_constraint(:target_resource_id, name: :resource_relationships_distinct_endpoints)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source_resource, name: :resource_relationships_tenant_source_fkey)
    |> assoc_constraint(:target_resource, name: :resource_relationships_tenant_endpoints_fkey)
    |> unique_constraint(
      [:organization_id, :source_resource_id, :target_resource_id, :kind],
      name: :resource_relationships_source_target_kind_index
    )
  end

  defp validate_distinct_resources(changeset) do
    if get_field(changeset, :source_resource_id) == get_field(changeset, :target_resource_id) do
      add_error(changeset, :target_resource_id, "must be different from source resource")
    else
      changeset
    end
  end
end
