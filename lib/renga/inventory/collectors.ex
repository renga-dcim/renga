defmodule Renga.Inventory.Collectors do
  @moduledoc """
  The targets of collector streams and what each target reports (RFD 11,
  "Observation payload").

  A scoped report lists the targets it covers. A reachable target is
  authoritative for the resources reported under it; an unreachable one is
  recorded as unreachable and its resources stay as they were, unknown rather
  than absent. Only a complete report that reached a target, and reconciled
  every resource under it, withdraws a resource the target no longer reports.

  Target state advances by the report's observed time, so a report replayed
  late from an agent's queue adds its evidence without regressing status or
  retiring anything.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Repo

  @doc """
  Lists the collector streams of an organization with their agent, by name.
  """
  def list_streams(%Scope{organization_id: organization_id}) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> where([source], not is_nil(source.collector_id))
    |> order_by([source], asc: source.name, asc: source.id)
    |> preload(:installation_agent)
    |> Repo.all()
  end

  @doc "Lists a stream's targets by key."
  def list_targets(%Scope{organization_id: organization_id}, source_id) do
    CollectorTarget
    |> where([target], target.organization_id == ^organization_id)
    |> where([target], target.source_id == ^source_id)
    |> order_by([target], asc: target.key)
    |> Repo.all()
  end

  @doc "Lists what a stream's targets reported, with each resource."
  def list_target_resources(%Scope{organization_id: organization_id}, source_id) do
    CollectorTargetResource
    |> where([member], member.organization_id == ^organization_id)
    |> where([member], member.source_id == ^source_id)
    |> order_by([member], asc: member.first_reported_at, asc: member.id)
    |> preload([:target, :resource])
    |> Repo.all()
  end

  @doc """
  Applies a reconciled report to its stream's targets. `results` pairs each
  derived observation with its reconciliation outcome. Returns the IDs of
  resources the report withdrew.

  Must run inside the reconciliation transaction, under the organization lock.
  """
  def apply_report!(%Scope{} = scope, %Source{} = source, %Observation{} = report, results) do
    resources_by_target =
      Enum.group_by(
        results,
        fn {derived, _result} -> derived.payload["target"] end,
        fn {_derived, result} -> result end
      )

    complete? = AgentPayload.complete_report?(report.payload)

    report.payload
    |> AgentPayload.report_targets()
    |> Enum.flat_map(fn reported ->
      target = put_target!(scope, source, report, reported)
      outcomes = Map.get(resources_by_target, reported.key, [])

      reported_ids =
        for {:ok, resource, _discovered?} <- outcomes, uniq: true do
          put_member!(scope, target, resource, report.observed_at)
          resource.id
        end

      # A failed resource leaves the target's contents unknown, so nothing
      # under it can be called gone.
      if complete? and reported.status == "reachable" and current_report?(target, report) and
           Enum.all?(outcomes, &match?({:ok, _resource, _discovered?}, &1)) do
        withdraw_unreported!(scope, source, target, reported_ids, report)
      else
        []
      end
    end)
  end

  defp put_target!(scope, source, report, reported) do
    observed_at = report.observed_at

    target =
      CollectorTarget
      |> where([target], target.organization_id == ^scope.organization_id)
      |> where([target], target.source_id == ^source.id and target.key == ^reported.key)
      |> lock("FOR UPDATE")
      |> Repo.one()

    reachable_at = if reported.status == "reachable", do: observed_at

    case target do
      nil ->
        Repo.insert!(%CollectorTarget{
          organization_id: scope.organization_id,
          source_id: source.id,
          key: reported.key,
          status: reported.status,
          error: reported.error,
          last_reported_at: observed_at,
          last_reachable_at: reachable_at,
          last_observation_id: report.id
        })

      %CollectorTarget{} = target ->
        if DateTime.compare(observed_at, target.last_reported_at) == :lt do
          # A late replay can still show the target was reachable then.
          target
          |> Ecto.Changeset.change(
            last_reachable_at: latest(target.last_reachable_at, reachable_at)
          )
          |> Repo.update!()
        else
          target
          |> Ecto.Changeset.change(
            status: reported.status,
            error: reported.error,
            last_reported_at: observed_at,
            last_reachable_at: latest(target.last_reachable_at, reachable_at),
            last_observation_id: report.id
          )
          |> Repo.update!()
        end
    end
  end

  defp current_report?(target, report), do: target.last_observation_id == report.id

  defp put_member!(scope, target, %Resource{} = resource, observed_at) do
    member =
      CollectorTargetResource
      |> where([member], member.organization_id == ^scope.organization_id)
      |> where([member], member.target_id == ^target.id and member.resource_id == ^resource.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case member do
      nil ->
        Repo.insert!(%CollectorTargetResource{
          organization_id: scope.organization_id,
          source_id: target.source_id,
          target_id: target.id,
          resource_id: resource.id,
          first_reported_at: observed_at,
          last_reported_at: observed_at
        })

      member ->
        member
        |> Ecto.Changeset.change(
          first_reported_at: earliest(member.first_reported_at, observed_at),
          last_reported_at: latest(member.last_reported_at, observed_at)
        )
        |> Repo.update!()
    end
  end

  defp withdraw_unreported!(scope, source, target, reported_ids, report) do
    withdrawn =
      CollectorTargetResource
      |> where([member], member.organization_id == ^scope.organization_id)
      |> where([member], member.target_id == ^target.id)
      |> where([member], member.resource_id not in ^reported_ids)
      |> where([member], member.last_reported_at < ^report.observed_at)
      |> where(
        [member],
        is_nil(member.withdrawn_at) or member.last_reported_at > member.withdrawn_at
      )
      |> Repo.all()

    Enum.map(withdrawn, fn member ->
      member
      |> Ecto.Changeset.change(withdrawn_at: report.observed_at)
      |> Repo.update!()

      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "withdrawn",
          field: "collector_targets",
          resource_id: member.resource_id,
          source_id: source.id,
          observation_id: report.id,
          old_value: %{"target" => target.key},
          occurred_at: report.observed_at
        })

      unless other_current_claim?(scope, member) do
        :ok = Inventory.mark_inventory_withdrawn!(scope, member.resource_id, report.observed_at)
      end

      member.resource_id
    end)
  end

  # Another stream's target still reports the resource, or a host agent
  # reports it directly. Either keeps its inventory current.
  defp other_current_claim?(scope, member) do
    present_elsewhere? =
      Repo.exists?(
        from other in CollectorTargetResource,
          where: other.organization_id == ^scope.organization_id,
          where: other.resource_id == ^member.resource_id and other.id != ^member.id,
          where: is_nil(other.withdrawn_at) or other.last_reported_at > other.withdrawn_at
      )

    present_elsewhere? or
      Repo.exists?(
        from reconciliation in ObservationReconciliation,
          join: observation in Observation,
          on: observation.id == reconciliation.observation_id,
          join: source in Source,
          on: source.id == observation.source_id,
          where: reconciliation.organization_id == ^scope.organization_id,
          where: reconciliation.matched_resource_id == ^member.resource_id,
          where: reconciliation.status == "succeeded",
          where: source.kind == "host_agent"
      )
  end

  defp latest(nil, datetime), do: datetime
  defp latest(datetime, nil), do: datetime

  defp latest(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp earliest(first, second),
    do: if(DateTime.compare(first, second) == :gt, do: second, else: first)
end
