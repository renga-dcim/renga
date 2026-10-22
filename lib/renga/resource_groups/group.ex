defmodule Renga.ResourceGroups.Group do
  @moduledoc """
  A named set of resources that people curate (RFD 18), such as `Staging` or
  a colocation customer. A resource may belong to any number of groups; a
  group belongs to at most one group set.

  Resource groups are unrelated to directory groups (RFD 16), which are
  groups of people.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.ResourceGroups.GroupSet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_groups" do
    field :name, :string
    field :description, :string
    # Direct members, filled by `Renga.ResourceGroups.list_groups/1`.
    field :member_count, :integer, virtual: true, default: 0

    belongs_to :organization, Organization
    belongs_to :group_set, GroupSet

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description, :group_set_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &blank_to_nil/1)
    |> update_change(:group_set_id, &blank_to_nil/1)
    |> validate_required([:organization_id, :name])
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name,
      name: :resource_groups_organization_name_index,
      message: "is already a group in this organization"
    )
    |> assoc_constraint(:group_set, name: :resource_groups_tenant_group_set_fkey)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
