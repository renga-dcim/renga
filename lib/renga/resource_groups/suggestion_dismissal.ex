defmodule Renga.ResourceGroups.SuggestionDismissal do
  @moduledoc """
  Remembers that a person dismissed one version of one triage rule's group
  suggestion. A resource/group has one suggestion row, but several rules may
  reach it; keeping each dismissal separately prevents unchanged rules from
  taking turns reopening the same suggestion.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_group_suggestion_dismissals" do
    field :rule_updated_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :suggestion, Renga.ResourceGroups.Suggestion
    belongs_to :rule, Renga.TriageRules.Rule

    timestamps()
  end
end
