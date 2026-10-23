defmodule Renga.ResourceGroups.Membership do
  @moduledoc """
  One materialized effective membership: the resource is in the group in
  this authorization view, through at least one path (RFD 18).

  The `inventory` view serves inventory workflow permissions; the `trusted`
  view serves `inventory.read`, `jobs.request`, and explicit permissions.
  Rows are derived, never edited: `Renga.ResourceGroups` rebuilds them in
  the transaction that changes their sources. `group_set_id` is set only
  while the group's set is exclusive, so a partial unique index refuses a
  second group of that set for the same resource and view.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "resource_group_memberships" do
    field :view, :string, primary_key: true

    belongs_to :organization, Renga.Accounts.Organization, primary_key: true
    belongs_to :resource, Renga.Inventory.Resource, primary_key: true
    belongs_to :group, Renga.ResourceGroups.Group, primary_key: true
    belongs_to :group_set, Renga.ResourceGroups.GroupSet
  end

  @doc "The authorization views, in the order RFD 18 describes them."
  def views, do: ~w(inventory trusted)
end
