defmodule Renga.Roles.Role do
  @moduledoc """
  A custom role: a named set of catalogue permissions defined by one
  organization (RFD 17, "Roles"). Built-in roles are not rows; their names
  are reserved here so a custom role can never be mistaken for one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Authorization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "roles" do
    field :name, :string
    field :description, :string
    field :permissions, {:array, :string}, default: []

    belongs_to :organization, Organization

    timestamps()
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :permissions])
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &blank_to_nil/1)
    |> update_change(
      :permissions,
      &(&1 |> Enum.reject(fn p -> p in [nil, ""] end) |> Enum.uniq() |> Enum.sort())
    )
    |> validate_required([:organization_id, :name])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 500)
    |> validate_change(:name, fn :name, name ->
      if String.downcase(name) in Authorization.built_in_roles(),
        do: [name: "is the name of a built-in role"],
        else: []
    end)
    |> validate_some_permission()
    |> validate_subset(:permissions, Authorization.permissions(),
      message: "has an unknown permission"
    )
    |> validate_subset(:permissions, Authorization.custom_role_permissions(),
      message: "can't include members.manage or roles.manage"
    )
    |> unique_constraint(:name,
      name: :roles_organization_name_index,
      message: "is already a role in this organization"
    )
  end

  defp validate_some_permission(changeset) do
    if get_field(changeset, :permissions) in [nil, []],
      do: add_error(changeset, :permissions, "choose at least one permission"),
      else: changeset
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
