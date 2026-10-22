defmodule Renga.Inventory.CompetingPlacements do
  @moduledoc """
  Opens a "VM active on two hypervisors" finding while competing fresh
  libvirt evidence leaves a VM's placement ambiguous (RFD 11,
  "Virtualization collection" and "Findings").

  Only active claims compete: a VM merely defined on two hypervisors, as a
  migration leaves it, is not a finding, and neither is a claim another
  hypervisor's later run has superseded. `Renga.Inventory.VmPlacements`
  decides; this module only files what it says.

  The finding is about the VM, whichever installations report its
  hypervisors, so it names no agent, and accepting it as an exception
  covers that VM. It resolves once placement is no longer ambiguous: one
  claim went stale, or the VM stopped on one side.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.VmPlacements
  alias Renga.Repo

  @kind "vm_active_on_two_hypervisors"

  @doc """
  Opens, updates, and resolves the organization's findings as of `now`, the
  server's clock. Runs inside the caller's transaction, under the
  organization lock.
  """
  def refresh!(%Scope{} = scope, now) do
    open = open_findings(scope)

    {ambiguous, settled} =
      scope
      |> candidates(now)
      |> MapSet.union(MapSet.new(Map.keys(open)))
      |> Enum.map(&{&1, VmPlacements.placement(scope, &1, now)})
      |> Enum.split_with(fn {_vm_id, placement} -> placement.status == :ambiguous end)

    Enum.each(ambiguous, fn {vm_id, placement} ->
      put!(scope, vm_id, Map.get(open, vm_id), placement)
    end)

    settled
    |> Enum.flat_map(fn {vm_id, _placement} -> List.wrap(Map.get(open, vm_id)) end)
    |> Enum.each(&resolve!(&1, now))
  end

  # VMs with active domain reports from two or more targets in the
  # freshness window: the only ones placement could find ambiguous.
  defp candidates(scope, now) do
    oldest = VmPlacements.oldest_fresh(now)

    CollectorTargetResource
    |> where([member], member.organization_id == ^scope.organization_id)
    |> where([member], not is_nil(member.active_since))
    |> where([member], member.domain_reported_at >= ^oldest)
    |> group_by([member], member.resource_id)
    |> having([member], count(member.target_id, :distinct) > 1)
    |> select([member], member.resource_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp open_findings(scope) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^scope.organization_id)
    |> where([finding], finding.kind == @kind and finding.status == "open")
    |> Repo.all()
    |> Map.new(&{&1.resource_id, &1})
  end

  defp put!(scope, vm_id, existing, placement) do
    hypervisors =
      placement.active
      |> Enum.map(&hypervisor_label/1)
      |> Enum.uniq()
      |> Enum.sort()

    details = %{
      "domain" => hd(placement.active).domain["name"],
      "hypervisors" => hypervisors,
      "claims" =>
        Enum.map(placement.active, fn claim ->
          %{
            "hypervisor" => hypervisor_label(claim),
            "active_since" => DateTime.to_iso8601(claim.active_since),
            "last_reported_at" => DateTime.to_iso8601(claim.last_reported_at)
          }
        end)
    }

    message =
      "libvirt reports it active on #{length(hypervisors)} hypervisors at once: " <>
        Enum.join(hypervisors, ", ")

    last_observed_at = placement.active |> Enum.map(& &1.last_reported_at) |> Enum.max(DateTime)

    case existing do
      nil ->
        Repo.insert!(%CollectorFinding{
          organization_id: scope.organization_id,
          resource_id: vm_id,
          kind: @kind,
          status: "open",
          message: message,
          details: details,
          last_observed_at: last_observed_at
        })

      finding ->
        finding
        |> Ecto.Changeset.change(
          message: message,
          details: details,
          last_observed_at: last_observed_at
        )
        |> Repo.update!()
    end
  end

  # A local URI such as qemu:///system names a different machine on each
  # installation, so the label says which installation reads it.
  defp hypervisor_label(%{target: target}) do
    uri = CollectorTarget.display_uri(target.key)

    case target.source.installation_agent do
      %{name: name} when is_binary(name) -> "#{uri} on #{name}"
      _agent -> uri
    end
  end

  defp resolve!(finding, now) do
    finding
    |> Ecto.Changeset.change(status: "resolved", resolved_at: now)
    |> Repo.update!()
  end
end
