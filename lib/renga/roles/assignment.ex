defmodule Renga.Roles.Assignment do
  @moduledoc """
  An assignment gives one role to one member, in addition to their base
  role (RFD 17, "Assignments"). The role is either a built-in role name or
  a custom role; an optional `valid_until` ends it, after which it grants
  nothing. Every assignment records who made it, when, and why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Roles.Role

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "role_assignments" do
    field :built_in_role, :string
    field :valid_until, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec
    field :source, :string, default: "manual"
    field :reason, :string

    belongs_to :organization, Organization
    belongs_to :membership, OrganizationMembership
    belongs_to :role, Role
    belongs_to :created_by_user, User

    timestamps()
  end

  @doc "Casts the deadline and reason; the role is set by `Renga.Assignments`."
  def changeset(assignment, attrs, now) do
    assignment
    |> cast(attrs, [:valid_until, :reason])
    |> update_change(:reason, &blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_change(:valid_until, fn :valid_until, valid_until ->
      if DateTime.compare(valid_until, now) == :gt,
        do: [],
        else: [valid_until: "must be in the future"]
    end)
    |> check_constraint(:built_in_role, name: :role_assignments_one_role)
  end

  @doc "Whether the assignment still grants its role at `now`."
  def current?(%__MODULE__{valid_until: nil}, _now), do: true
  def current?(%__MODULE__{valid_until: until}, now), do: DateTime.compare(until, now) == :gt

  @doc "The role's name for people: the built-in name or the custom role's."
  def role_name(%__MODULE__{built_in_role: role}) when is_binary(role), do: role
  def role_name(%__MODULE__{role: %Role{name: name}}), do: name

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
