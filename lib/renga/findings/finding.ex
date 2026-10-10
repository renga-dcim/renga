defmodule Renga.Findings.Finding do
  @moduledoc """
  One finding from any domain, in the shape the Inbox reads.

  Component, hardware match, placement, topology, and address findings live in their
  own tables with their own reconcilers; this struct is the common read
  model `Renga.Findings` builds over them, joined with the finding's
  workflow state. It is not persisted.

  `state` is where the finding sits in the queue: `:open` needs attention,
  `:snoozed` and `:excepted` are open findings people set aside, and
  `:resolved` means reconciliation no longer observes the condition.
  """

  @enforce_keys [:domain, :id, :kind]
  defstruct [
    :domain,
    :id,
    :kind,
    :group,
    :state,
    :status,
    :message,
    :details,
    :resolution_key,
    :subject_id,
    :resource,
    :interface_id,
    :interface_name,
    :workflow,
    :opened_at,
    :last_observed_at,
    :resolved_at
  ]
end
