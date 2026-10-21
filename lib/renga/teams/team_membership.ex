defmodule Renga.Teams.TeamMembership do
  @moduledoc """
  A person on a team (RFD 17). The person is an organization membership, so
  disabling or removing them from the organization takes them off its teams
  too, as far as access is concerned.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Teams.Team

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "team_memberships" do
    belongs_to :organization, Organization
    belongs_to :team, Team
    belongs_to :membership, OrganizationMembership
    belongs_to :added_by_user, User

    timestamps()
  end
end
