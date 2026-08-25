defmodule Renga.DCIM.Site do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(planned active staging decommissioning retired)

  schema "sites" do
    field :slug, :string
    field :status, :string, default: "active"
    field :description, :string
    field :physical_address, :string
    field :time_zone, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site_group, Renga.DCIM.SiteGroup
    has_many :locations, Renga.DCIM.Location
    has_many :racks, Renga.DCIM.Rack
    timestamps()
  end

  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :site_group_id,
      :slug,
      :status,
      :description,
      :physical_address,
      :time_zone,
      :metadata
    ])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:organization_id, :resource_id, :slug, :status])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_inclusion(:status, @statuses)
    |> validate_time_zone()
    |> assoc_constraint(:resource, name: :sites_organization_resource_fkey)
    |> assoc_constraint(:site_group, name: :sites_organization_site_group_fkey)
    |> unique_constraint([:organization_id, :slug])
  end

  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, value ->
      case DateTime.now(value) do
        {:ok, _datetime} -> []
        {:error, _reason} -> [time_zone: "is invalid"]
      end
    end)
  end
end
