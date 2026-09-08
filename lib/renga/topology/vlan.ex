defmodule Renga.Topology.Vlan do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(active reserved deprecated)

  schema "vlans" do
    field :vid, :integer
    field :name, :string
    field :status, :string, default: "active"
    field :role, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :vlan_group, Renga.Topology.VlanGroup
    timestamps()
  end

  def changeset(vlan, attrs) do
    vlan
    |> cast(attrs, [:vlan_group_id, :vid, :name, :status, :role, :description, :metadata])
    |> update_change(:name, &trim_string/1)
    |> update_change(:role, &trim_string/1)
    |> validate_required([:organization_id, :resource_id, :vid, :name, :status, :metadata])
    |> validate_number(:vid, greater_than_or_equal_to: 1, less_than_or_equal_to: 4094)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 255, count: :codepoints)
    |> validate_length(:role, max: 255, count: :codepoints)
    |> validate_uuid(:vlan_group_id)
    |> validate_map(:metadata)
    |> assoc_constraint(:resource, name: :vlans_organization_resource_fkey)
    |> assoc_constraint(:vlan_group, name: :vlans_organization_group_fkey)
    |> check_constraint(:vid, name: :vlans_valid_vid)
    |> unique_constraint([:organization_id, :vlan_group_id, :vid],
      name: :vlans_organization_group_vid_index
    )
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

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
