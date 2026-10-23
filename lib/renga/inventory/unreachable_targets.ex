defmodule Renga.Inventory.UnreachableTargets do
  @moduledoc """
  Opens a "target unreachable" finding when a switch or hypervisor a
  collector stream is configured to poll has not answered for longer than
  its freshness window (RFD 11, "Findings").

  A target counts as configured while its stream keeps reporting it: an
  unreachable target is still listed in every report, so one that has not
  been reported for a whole window was taken out of the module's
  configuration, or its installation went silent, which the Collectors page
  shows as a disconnected installation instead.

  The finding is filed on what the target reported: the switch or hosts it
  still presents. A target that has never been reached reported nothing,
  so its finding is filed on the installation's own host, which is where
  someone fixes a mistyped address or a missing route.

  The window is three polls at the module's default interval: 45 minutes for
  a switch poller, and 15 for libvirt, the window VM placement uses. Reports
  carry no interval, so a module polling less often than its default opens
  the finding at its first unreachable poll after a window.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Repo

  @kind "target_unreachable"
  @windows %{"switch_poller" => 45 * 60, "vm_provider" => 15 * 60}

  @doc "The freshness window, in seconds, of a stream kind's targets."
  def window_seconds(kind), do: Map.fetch!(@windows, kind)

  @doc """
  Opens, updates, and resolves the organization's target-unreachable
  findings as of `now`, the server's clock. Runs inside the caller's
  transaction, under the organization lock.
  """
  def refresh!(%Scope{} = scope, now) do
    desired =
      scope
      |> overdue_targets(now)
      |> Enum.flat_map(&entries(scope, &1, now))

    Repo.insert_all(CollectorFinding, desired,
      on_conflict: {:replace, [:message, :details, :last_observed_at, :updated_at]},
      conflict_target:
        {:unsafe_fragment,
         "(organization_id, resource_id, agent_id, kind, target_id) WHERE status = 'open'"}
    )

    keep = MapSet.new(desired, &{&1.resource_id, &1.target_id})

    CollectorFinding
    |> where([finding], finding.organization_id == ^scope.organization_id)
    |> where([finding], finding.kind == @kind and finding.status == "open")
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keep, {&1.resource_id, &1.target_id}))
    |> Enum.map(& &1.id)
    |> resolve!(scope, now)
  end

  # Unreachable on its latest report, still reported within the window, and
  # not reached within it. A target that was never reached counts from when
  # it was first reported.
  defp overdue_targets(scope, now) do
    CollectorTarget
    |> where([target], target.organization_id == ^scope.organization_id)
    |> where([target], target.status == "unreachable")
    |> preload(source: :installation_agent)
    |> Repo.all()
    |> Enum.filter(&overdue?(&1, now))
  end

  defp overdue?(%CollectorTarget{source: source} = target, now) do
    case Map.fetch(@windows, source.kind) do
      {:ok, window} ->
        oldest = DateTime.add(now, -window)
        last_answer = target.last_reachable_at || target.inserted_at

        not is_nil(source.installation_agent) and
          DateTime.compare(target.last_reported_at, oldest) != :lt and
          DateTime.compare(last_answer, oldest) == :lt

      :error ->
        false
    end
  end

  defp entries(scope, target, now) do
    agent = target.source.installation_agent
    key = display_key(target)

    details = %{
      "collector_id" => target.source.collector_id,
      "collector_kind" => target.source.kind,
      "target" => key,
      "error" => target.error,
      "last_reachable_at" =>
        target.last_reachable_at && DateTime.to_iso8601(target.last_reachable_at),
      "window_seconds" => window_seconds(target.source.kind)
    }

    since =
      case target.last_reachable_at do
        nil -> "has never reached #{key}"
        at -> "has not reached #{key} since #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}"
      end

    message = "Collector #{target.source.collector_id} #{since}"

    for resource_id <- filed_on(scope, target, agent) do
      %{
        id: Ecto.UUID.generate(),
        organization_id: scope.organization_id,
        resource_id: resource_id,
        agent_id: agent.id,
        target_id: target.id,
        kind: @kind,
        status: "open",
        message: message,
        details: details,
        last_observed_at: target.last_reported_at,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp display_key(%CollectorTarget{source: %{kind: "vm_provider"}, key: key}),
    do: CollectorTarget.display_uri(key)

  defp display_key(%CollectorTarget{key: key}), do: key

  # What the target still presents, or else the installation's own host.
  defp filed_on(scope, target, agent) do
    case present_resources(scope, target) do
      [] -> host_resources(scope, agent)
      resource_ids -> resource_ids
    end
  end

  defp present_resources(scope, target) do
    CollectorTargetResource
    |> where([member], member.organization_id == ^scope.organization_id)
    |> where([member], member.target_id == ^target.id)
    |> where(
      [member],
      is_nil(member.withdrawn_at) or member.last_reported_at > member.withdrawn_at
    )
    |> select([member], member.resource_id)
    |> Repo.all()
  end

  defp host_resources(_scope, %{source_id: nil}), do: []

  defp host_resources(scope, %{source_id: source_id}) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^scope.organization_id)
    |> where([claim], claim.source_id == ^source_id)
    |> distinct(true)
    |> select([claim], claim.resource_id)
    |> Repo.all()
  end

  defp resolve!([], _scope, _now), do: :ok

  defp resolve!(ids, scope, now) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^scope.organization_id)
    |> where([finding], finding.id in ^ids)
    |> Repo.update_all(set: [status: "resolved", resolved_at: now, updated_at: now])

    :ok
  end
end
