defmodule Renga.Topology.VlanGroup do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @scope_kinds ~w(global site location)
  @statuses ~w(active reserved deprecated)

  schema "vlan_groups" do
    field :slug, :string
    field :scope_kind, :string, default: "global"
    field :status, :string, default: "active"
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site, Renga.DCIM.Site
    belongs_to :location, Renga.DCIM.Location
    has_many :vid_ranges, Renga.Topology.VlanGroupVidRange
    has_many :vlans, Renga.Topology.Vlan
    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:slug, :scope_kind, :site_id, :location_id, :status, :description, :metadata])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:organization_id, :resource_id, :slug, :scope_kind, :status, :metadata])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_length(:slug, max: 255, count: :codepoints)
    |> validate_inclusion(:scope_kind, @scope_kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_uuid(:site_id)
    |> validate_uuid(:location_id)
    |> validate_scope()
    |> validate_map(:metadata)
    |> assoc_constraint(:resource, name: :vlan_groups_organization_resource_fkey)
    |> assoc_constraint(:site, name: :vlan_groups_organization_site_fkey)
    |> assoc_constraint(:location, name: :vlan_groups_organization_location_fkey)
    |> check_constraint(:scope_kind, name: :vlan_groups_valid_scope)
    |> unique_constraint([:organization_id, :slug])
  end

  defp validate_scope(changeset) do
    case {
      get_field(changeset, :scope_kind),
      get_field(changeset, :site_id),
      get_field(changeset, :location_id)
    } do
      {"global", nil, nil} -> changeset
      {"site", site_id, nil} when not is_nil(site_id) -> changeset
      {"location", nil, location_id} when not is_nil(location_id) -> changeset
      _invalid -> add_error(changeset, :scope_kind, "does not match the selected scope")
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp validate_uuid(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, nil} ->
        changeset

      {:ok, value} ->
        with {:ok, _binary} <- Ecto.UUID.dump(value),
             {:ok, canonical} <- Ecto.UUID.cast(value) do
          put_change(changeset, field, canonical)
        else
          :error -> add_error(changeset, field, "is invalid")
        end

      :error ->
        changeset
    end
  end

  defp normalize_slug(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_slug(value), do: value
end
