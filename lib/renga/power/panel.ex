defmodule Renga.Power.Panel do
  @moduledoc """
  A power panel placed at a site, optionally inside one of its locations
  (RFD 10, "Model"). Its feeds are the circuits it supplies.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "power_panels" do
    field :name, :string
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site, Renga.DCIM.Site
    belongs_to :location, Renga.DCIM.Location
    has_many :feeds, Renga.Power.Feed

    timestamps()
  end

  def changeset(panel, attrs) do
    panel
    |> cast(attrs, [:site_id, :location_id, :name, :description, :metadata])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organization_id, :resource_id, :site_id, :name])
    |> validate_length(:name, max: 255, count: :codepoints)
    |> assoc_constraint(:resource, name: :power_panels_organization_resource_fkey)
    |> assoc_constraint(:site, name: :power_panels_organization_site_fkey)
    |> assoc_constraint(:location, name: :power_panels_site_location_fkey)
    |> unique_constraint(:name,
      name: :power_panels_organization_id_site_id_name_index,
      message: "is already used by a panel at this site"
    )
  end
end
