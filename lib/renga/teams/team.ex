defmodule Renga.Teams.Team do
  @moduledoc """
  A group in an organization that answers for resources. Teams are named by
  people; a resource's owning team is one of the facts triage asks for.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "teams" do
    field :name, :string
    field :description, :string
    # Resources the team owns, filled by `Renga.Teams.list_teams/1`.
    field :resource_count, :integer, virtual: true, default: 0

    belongs_to :organization, Organization

    timestamps()
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &blank_to_nil/1)
    |> validate_required([:organization_id, :name])
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name,
      name: :teams_organization_name_index,
      message: "is already a team in this organization"
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
