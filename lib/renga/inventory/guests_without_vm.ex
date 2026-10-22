defmodule Renga.Inventory.GuestsWithoutVm do
  @moduledoc """
  Opens a "guest without a VM" finding for a KVM guest whose SMBIOS UUID
  matches no domain on any reporting hypervisor (RFD 11, "Findings").

  It is off unless the organization opts in: while libvirt collection is
  still being rolled out it would flag every guest on an uncollected
  hypervisor. Turning it off resolves every open one.

  A guest is a machine a connected host agent reports with a `dmi_uuid`,
  whose latest successful host report says it runs as a KVM or QEMU VM. A
  libvirt domain with that UUID reconciles to the same resource (RFD 11,
  "Virtualization collection"), so the guest matches a domain when any
  hypervisor stream still presents it with a domain. Other virtualization
  (VMware, cloud providers) is never reported by libvirt, so it never
  qualifies, and a guest without a UUID is the possible-same-machine
  finding's to judge instead.

  The finding is filed per agent, like the installation key finding. It
  resolves when a hypervisor reports the domain, the agent disconnects, or
  the guest stops looking like a KVM guest.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.Source
  alias Renga.Repo

  @kind "guest_without_vm"
  @libvirt_providers ~w(kvm qemu)

  @doc "Whether the organization opted in to the finding."
  def enabled?(%Scope{organization_id: organization_id}) do
    Repo.one!(
      from organization in Organization,
        where: organization.id == ^organization_id,
        select: organization.guest_without_vm_findings
    )
  end

  @doc """
  Opens, updates, and resolves the organization's findings as of `now`, the
  server's clock. Runs inside the caller's transaction, under the
  organization lock.
  """
  def refresh!(%Scope{} = scope, now) do
    if enabled?(scope) do
      desired = scope |> guests_without_domain(:all) |> entries(scope, now)
      put!(scope, desired, :all, now)
    else
      resolve_except!(scope, :all, MapSet.new(), now)
    end
  end

  @doc "Like `refresh!/2`, for the one machine a host agent just reported."
  def refresh_guest!(%Scope{} = scope, resource_id, now) do
    if enabled?(scope) do
      desired = scope |> guests_without_domain([resource_id]) |> entries(scope, now)
      put!(scope, desired, [resource_id], now)
    else
      :ok
    end
  end

  # Machines with a reported SMBIOS UUID that no hypervisor presents with a
  # domain, by the agents reporting them.
  defp guests_without_domain(scope, resource_ids) do
    with_domain =
      CollectorTargetResource
      |> where([member], member.organization_id == ^scope.organization_id)
      |> where([member], not is_nil(member.domain))
      |> where(
        [member],
        is_nil(member.withdrawn_at) or member.last_reported_at > member.withdrawn_at
      )
      |> select([member], member.resource_id)

    ResourceIdentifier
    |> join(:inner, [identifier], claim in ResourceIdentifierClaim,
      on:
        claim.organization_id == identifier.organization_id and
          claim.resource_id == identifier.resource_id
    )
    |> join(:inner, [_identifier, claim], source in Source, on: source.id == claim.source_id)
    |> join(:inner, [_identifier, _claim, source], agent in Agent,
      on: agent.source_id == source.id and agent.organization_id == source.organization_id
    )
    |> where([identifier], identifier.organization_id == ^scope.organization_id)
    |> where([identifier], identifier.kind == "dmi_uuid")
    |> where([_identifier, _claim, source], source.kind == "host_agent")
    |> where([identifier], identifier.resource_id not in subquery(with_domain))
    |> only(resource_ids)
    |> distinct(true)
    |> select([identifier, _claim, _source, agent], {identifier.resource_id, agent})
    |> Repo.all()
    |> with_leases()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp with_leases(rows) do
    agents =
      rows
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq_by(& &1.id)
      |> Repo.preload(:lease)
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn {resource_id, agent} -> {resource_id, Map.fetch!(agents, agent.id)} end)
  end

  defp only(query, :all), do: query

  defp only(query, resource_ids),
    do: where(query, [identifier], identifier.resource_id in ^resource_ids)

  defp entries(guests, scope, now) do
    environments = environments(scope, Map.keys(guests))

    for {resource_id, agents} <- guests,
        provider = libvirt_provider(Map.get(environments, resource_id)),
        not is_nil(provider),
        agent <- agents,
        connected?(agent, now) do
      %{
        id: Ecto.UUID.generate(),
        organization_id: scope.organization_id,
        resource_id: resource_id,
        agent_id: agent.id,
        kind: @kind,
        status: "open",
        message:
          "It runs as a #{provider} guest, but no reporting hypervisor defines a VM " <>
            "with its SMBIOS UUID",
        details: %{"provider" => provider, "installation_id" => agent.installation_id},
        last_observed_at: now,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # The virtualization component of each machine's latest successful host
  # report, which the agent sends but no table keeps.
  defp environments(_scope, []), do: %{}

  defp environments(scope, resource_ids) do
    ObservationReconciliation
    |> join(:inner, [reconciliation], observation in Observation,
      on: observation.id == reconciliation.observation_id
    )
    |> join(:inner, [_reconciliation, observation], source in Source,
      on: source.id == observation.source_id
    )
    |> where([reconciliation], reconciliation.organization_id == ^scope.organization_id)
    |> where([reconciliation], reconciliation.matched_resource_id in ^resource_ids)
    |> where([reconciliation], reconciliation.status == "succeeded")
    |> where([_reconciliation, _observation, source], source.kind == "host_agent")
    |> distinct([reconciliation], reconciliation.matched_resource_id)
    |> order_by([reconciliation, observation],
      asc: reconciliation.matched_resource_id,
      desc: observation.observed_at,
      desc: observation.id
    )
    |> select([reconciliation, observation], {
      reconciliation.matched_resource_id,
      fragment("?->'resources'->0->'components'", observation.payload)
    })
    |> Repo.all()
    |> Map.new()
  end

  defp libvirt_provider(components) when is_list(components) do
    Enum.find_value(components, fn
      %{"kind" => "virtualization", "environment" => "vm_guest", "provider" => provider}
      when provider in @libvirt_providers ->
        provider

      _other ->
        nil
    end)
  end

  defp libvirt_provider(_components), do: nil

  defp connected?(%Agent{status: "active", lease: %AgentLease{} = lease}, now),
    do: not AgentLease.expired?(lease, now)

  defp connected?(_agent, _now), do: false

  defp put!(scope, desired, resource_ids, now) do
    Repo.insert_all(CollectorFinding, desired,
      on_conflict: {:replace, [:message, :details, :last_observed_at, :updated_at]},
      conflict_target:
        {:unsafe_fragment,
         "(organization_id, resource_id, agent_id, kind, target_id) WHERE status = 'open'"}
    )

    resolve_except!(scope, resource_ids, MapSet.new(desired, &{&1.resource_id, &1.agent_id}), now)
  end

  defp resolve_except!(scope, resource_ids, keep, now) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^scope.organization_id)
    |> where([finding], finding.kind == @kind and finding.status == "open")
    |> then(fn query ->
      if resource_ids == :all,
        do: query,
        else: where(query, [finding], finding.resource_id in ^resource_ids)
    end)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keep, {&1.resource_id, &1.agent_id}))
    |> Enum.map(& &1.id)
    |> case do
      [] ->
        :ok

      ids ->
        CollectorFinding
        |> where([finding], finding.id in ^ids)
        |> Repo.update_all(set: [status: "resolved", resolved_at: now, updated_at: now])

        :ok
    end
  end
end
