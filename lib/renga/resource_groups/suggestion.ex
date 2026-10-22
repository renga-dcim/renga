defmodule Renga.ResourceGroups.Suggestion do
  @moduledoc """
  A triage rule's suggestion that a resource join a group (RFD 18). It
  changes nothing until a person accepts it, which is an ordinary direct
  membership change by that person; dismissing it keeps it from being
  raised again until the rule changes (`rule_updated_at`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_group_suggestions" do
    field :rule_name, :string
    field :rule_updated_at, :utc_datetime_usec
    field :status, :string, default: "open"
    field :decided_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :group, Renga.ResourceGroups.Group
    belongs_to :rule, Renga.TriageRules.Rule
    belongs_to :decided_by_user, Renga.Accounts.User

    timestamps()
  end
end
