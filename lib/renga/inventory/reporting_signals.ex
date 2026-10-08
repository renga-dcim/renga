defmodule Renga.Inventory.ReportingSignals do
  @moduledoc """
  What each collector's latest report says about how a resource reaches
  Renga (RFD 8, "Triage"): the address the report arrived from, the intake
  key it used, and the labels the collector was configured to send.

  Signals come from each source's latest report that reconciliation matched
  to the resource, so a host that moves networks or changes labels shows its
  current signals. Triage rules match these; the resource's Sources tab
  shows them so people can see why a rule matched.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Resource
  alias Renga.Repo

  defstruct [:source, :observed_at, :reported_from, :intake_api_key, labels: %{}]

  @doc "The latest signals from each source that reports the resource, by source name."
  def for_resource(%Scope{organization_id: organization_id}, %Resource{id: resource_id}) do
    from(observation in Observation,
      join: reconciliation in ObservationReconciliation,
      on:
        reconciliation.observation_id == observation.id and
          reconciliation.organization_id == ^organization_id,
      where: observation.organization_id == ^organization_id,
      where: reconciliation.matched_resource_id == ^resource_id,
      where: reconciliation.status == "succeeded",
      distinct: observation.source_id,
      order_by: [asc: observation.source_id, desc: observation.observed_at, desc: observation.id],
      preload: [:source, :intake_api_key]
    )
    |> Repo.all()
    |> Enum.map(&from_observation/1)
    |> Enum.sort_by(& &1.source.name)
  end

  @doc "Every label the resource's collectors report, merged; later sources by name win ties."
  def labels(signals), do: Enum.reduce(signals, %{}, &Map.merge(&2, &1.labels))

  defp from_observation(observation) do
    %__MODULE__{
      source: observation.source,
      observed_at: observation.observed_at,
      reported_from: observation.reported_from,
      intake_api_key: observation.intake_api_key,
      labels: payload_labels(observation.payload)
    }
  end

  # Only validated agent payloads carry labels; anything else reads as none.
  defp payload_labels(%{"resources" => [%{"labels" => %{} = labels} | _rest]}),
    do: Map.filter(labels, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp payload_labels(_payload), do: %{}
end
