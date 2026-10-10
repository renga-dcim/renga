defmodule Renga.IPAM.PlanLevel do
  @moduledoc """
  One level of an organization's addressing plan (RFD 4, "Addressing plan
  and allocation"): a child prefix length of one address family and what a
  block of that length is for, such as `/56` "hall".

  A family's levels, ordered by length, are its plan. A container is
  counted and mapped in the first planned length longer than its own; a
  family with no level deeper than a container keeps the guess from its
  children.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @families ~w(ipv4 ipv6)

  schema "addressing_plan_levels" do
    field :family, :string
    field :prefix_length, :integer
    field :name, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :created_by, Renga.Accounts.User

    timestamps()
  end

  def changeset(level, attrs) do
    level
    |> cast(attrs, [:family, :prefix_length, :name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organization_id, :family, :prefix_length, :name])
    |> validate_inclusion(:family, @families)
    |> validate_length(:name, max: 64)
    |> validate_length()
    |> unique_constraint(:prefix_length,
      name: :addressing_plan_levels_family_length_index,
      message: "is already a level of this family's plan"
    )
    |> check_constraint(:prefix_length, name: :addressing_plan_levels_valid_length)
  end

  def families, do: @families

  # A level is a child length: never the whole space, never a single host.
  defp validate_length(changeset) do
    max = if get_field(changeset, :family) == "ipv6", do: 127, else: 31

    validate_number(changeset, :prefix_length,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: max,
      message: "must be between 1 and #{max}"
    )
  end
end
