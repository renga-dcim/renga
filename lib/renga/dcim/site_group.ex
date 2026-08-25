defmodule Renga.DCIM.SiteGroup do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "site_groups" do
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :parent, __MODULE__
    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:parent_id, :description, :metadata])
    |> validate_required([:organization_id, :resource_id])
    |> assoc_constraint(:resource, name: :site_groups_organization_resource_fkey)
    |> assoc_constraint(:parent, name: :site_groups_organization_parent_fkey)
    |> check_constraint(:parent_id, name: :site_groups_not_self_parent)
  end
end
