defmodule Renga.DCIM.Location do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(planned active staging decommissioning retired)

  schema "locations" do
    field :kind, :string
    field :status, :string, default: "active"
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site, Renga.DCIM.Site
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :racks, Renga.DCIM.Rack
    timestamps()
  end

  def changeset(location, attrs) do
    location
    |> cast(attrs, [:site_id, :parent_id, :kind, :status, :description, :metadata])
    |> validate_required([:organization_id, :resource_id, :site_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:resource, name: :locations_organization_resource_fkey)
    |> assoc_constraint(:site, name: :locations_organization_site_fkey)
    |> assoc_constraint(:parent, name: :locations_site_parent_fkey)
    |> check_constraint(:parent_id, name: :locations_not_self_parent)
  end
end
