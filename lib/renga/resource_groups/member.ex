defmodule Renga.ResourceGroups.Member do
  @moduledoc """
  A direct membership: a person put this resource in this group. Agents,
  reconcilers, and triage rules never write one, so direct membership is a
  trusted attribute in RFD 17's sense.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "resource_group_members" do
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :group, Renga.ResourceGroups.Group
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :added_by_user, Renga.Accounts.User

    timestamps()
  end
end
