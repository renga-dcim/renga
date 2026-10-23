defmodule Renga.ResourceGroups.GroupSet do
  @moduledoc """
  A named family of resource groups, such as `Environment` with
  `Production`, `Staging`, and `Lab` (RFD 18). An exclusive set lets a
  resource belong to at most one of its groups, through any path, which gives
  the guarantee of a single label key without trusting reported data.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_group_sets" do
    field :name, :string
    field :description, :string
    field :exclusive, :boolean, default: false

    belongs_to :organization, Organization
    has_many :groups, Renga.ResourceGroups.Group, foreign_key: :group_set_id

    timestamps()
  end

  def changeset(set, attrs) do
    set
    |> cast(attrs, [:name, :description, :exclusive])
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &blank_to_nil/1)
    |> validate_required([:organization_id, :name])
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name,
      name: :resource_group_sets_organization_name_index,
      message: "is already a group set in this organization"
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
