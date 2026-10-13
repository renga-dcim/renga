defmodule Renga.Inventory.CollectionClocks do
  @moduledoc """
  The four collection clocks of each source, kept apart so that one never
  stands in for another (RFD 1, "Collection model"):

    * contact: the latest authenticated API request, even one whose payload
      was rejected (`Agent.last_contacted_at`);
    * lease: the latest renewal and its expiry, renewed only by an accepted
      check-in or observation (`AgentLease`);
    * accepted: when Renga last accepted an observation from the source, by
      Renga's clock, whether or not it reconciled;
    * reconciled: the observed time of the newest observation that reconciled
      successfully, which is how current the inventory Renga applied is.

  A check-in moves only contact and lease. An observation that is accepted
  but fails to reconcile moves accepted without moving reconciled, and
  `latest_outcome` says so.

  This module computes the two inventory clocks; contact and lease come with
  the agent and its lease.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Repo

  defstruct [:accepted_at, :reconciled_observed_at, :latest_outcome]

  @type t :: %__MODULE__{
          accepted_at: DateTime.t() | nil,
          reconciled_observed_at: DateTime.t() | nil,
          latest_outcome: String.t() | nil
        }

  @doc """
  The inventory clocks of every source in the scope that has sent an
  observation, by source ID. `latest_outcome` is the status of the latest
  reconciliation attempt of the source's most recently accepted observation:
  `"succeeded"`, `"failed"`, `"pending"`, `"running"`, or `nil` before any
  attempt.
  """
  def by_source(%Scope{organization_id: organization_id}) do
    accepted = accepted_at(organization_id)
    reconciled = reconciled_observed_at(organization_id)
    outcomes = latest_outcomes(organization_id)

    Map.new(accepted, fn {source_id, accepted_at} ->
      {source_id,
       %__MODULE__{
         accepted_at: accepted_at,
         reconciled_observed_at: Map.get(reconciled, source_id),
         latest_outcome: Map.get(outcomes, source_id)
       }}
    end)
  end

  defp accepted_at(organization_id) do
    from(observation in Observation,
      where: observation.organization_id == ^organization_id,
      group_by: observation.source_id,
      select: {observation.source_id, max(observation.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp reconciled_observed_at(organization_id) do
    from(observation in Observation,
      join: reconciliation in ObservationReconciliation,
      on:
        reconciliation.observation_id == observation.id and
          reconciliation.organization_id == observation.organization_id,
      where: observation.organization_id == ^organization_id,
      where: reconciliation.status == "succeeded",
      group_by: observation.source_id,
      select: {observation.source_id, max(observation.observed_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp latest_outcomes(organization_id) do
    latest_observations =
      from(observation in Observation,
        where: observation.organization_id == ^organization_id,
        distinct: observation.source_id,
        order_by: [
          asc: observation.source_id,
          desc: observation.inserted_at,
          desc: observation.id
        ],
        select: %{id: observation.id, source_id: observation.source_id}
      )

    from(latest in subquery(latest_observations),
      left_join: reconciliation in ObservationReconciliation,
      on:
        reconciliation.observation_id == latest.id and
          reconciliation.organization_id == ^organization_id,
      distinct: latest.source_id,
      order_by: [asc: latest.source_id, desc_nulls_last: reconciliation.attempt],
      select: {latest.source_id, reconciliation.status}
    )
    |> Repo.all()
    |> Map.new()
  end
end
