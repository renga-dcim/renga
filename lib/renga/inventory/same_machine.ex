defmodule Renga.Inventory.SameMachine do
  @moduledoc """
  Opens a "possible same machine" finding when a host agent's machine has no
  usable SMBIOS UUID but its MAC addresses cover every MAC address of exactly
  one fresh libvirt domain (RFD 11, "Virtualization collection").

  MAC addresses are reassigned, cloned with images, and spoofable, so they
  never merge two resources. The finding carries the evidence for a person;
  accepting it as an exception in the Inbox suppresses it for that machine.
  It resolves when the evidence no longer singles out one domain, or once
  the guest reports a UUID and correlates by it.

  Evaluation follows each reconciliation, as of the observation's time,
  whenever a host agent reports a machine or a hypervisor reports domains.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.Source
  alias Renga.Inventory.VmPlacements
  alias Renga.Repo
  alias Renga.Types.MacAddress

  @kind "possible_same_machine"

  @doc """
  Re-evaluates what a reconciled observation may have changed: the machine a
  host agent reported, or the machines a hypervisor's domains could match.
  Runs after reconciliation commits, under the organization lock.
  """
  def refresh_after!(%Scope{} = scope, %Observation{} = observation, result) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(scope.organization_id)
      refresh_observation!(scope, observation, result)
    end)
  end

  defp refresh_observation!(
         scope,
         %Observation{payload: %{"scope" => "hypervisor"} = payload} = observation,
         {:ok, resources, _discovered?}
       )
       when is_list(resources) do
    macs =
      for %{"domain" => %{"interfaces" => [_ | _] = interfaces}} <- payload["resources"] || [],
          %{"mac_address" => mac} <- interfaces,
          do: mac

    withdrawn =
      case scope |> Inventory.list_observation_reconciliations(observation.id) |> List.last() do
        %{metadata: %{"withdrawn_resource_ids" => ids}} -> ids
        _none -> []
      end

    refresh_for_domains!(
      scope,
      macs,
      Enum.map(resources, & &1.id) ++ withdrawn,
      observation.observed_at
    )
  end

  defp refresh_observation!(scope, %Observation{} = observation, {:ok, %Resource{} = resource, _}) do
    if Inventory.get_source!(scope, observation.source_id).kind == "host_agent",
      do: refresh_guest!(scope, resource.id, observation.observed_at)
  end

  defp refresh_observation!(_scope, _observation, _result), do: :ok

  @doc """
  Re-evaluates the machines that could match the given domains: those with
  an interface carrying one of `macs`, and those whose open finding names
  one of `vm_resource_ids`.
  """
  def refresh_for_domains!(%Scope{} = scope, macs, vm_resource_ids, now) do
    macs = Enum.flat_map(macs, &cast_mac/1)

    by_mac =
      Interface
      |> where([interface], interface.organization_id == ^scope.organization_id)
      |> where([interface], interface.mac_address in ^macs)
      |> select([interface], interface.resource_id)

    vm_ids = Enum.map(vm_resource_ids, &to_string/1)

    by_finding =
      CollectorFinding
      |> where([finding], finding.organization_id == ^scope.organization_id)
      |> where([finding], finding.kind == @kind and finding.status == "open")
      |> where([finding], fragment("?->>'vm_resource_id'", finding.details) in ^vm_ids)
      |> select([finding], finding.resource_id)

    by_mac
    |> union(^by_finding)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.each(&refresh_guest!(scope, &1, now))
  end

  @doc "Opens, updates, or resolves the finding for one machine as of `now`."
  def refresh_guest!(%Scope{} = scope, guest_id, now) do
    case guest_agents(scope, guest_id) do
      [] ->
        resolve_where!(scope, guest_id, now, & &1)

      agents ->
        case candidate(scope, guest_id, now) do
          nil -> resolve_where!(scope, guest_id, now, & &1)
          {vm_id, members, macs} -> open!(scope, guest_id, agents, vm_id, members, macs, now)
        end
    end
  end

  defp candidate(scope, guest_id, now) do
    guest_macs = guest_macs(scope, guest_id)

    if guest_macs == MapSet.new() or uuid?(scope, guest_id) do
      nil
    else
      matches =
        scope
        |> fresh_domains(guest_id, now)
        |> Enum.filter(fn {_member, macs} ->
          macs != MapSet.new() and MapSet.subset?(macs, guest_macs)
        end)

      case Enum.group_by(matches, fn {member, _macs} -> member.resource_id end) do
        %{} = by_vm when map_size(by_vm) == 1 ->
          [{vm_id, [{_member, macs} | _rest] = vm_matches}] = Map.to_list(by_vm)
          {vm_id, Enum.map(vm_matches, &elem(&1, 0)), macs}

        _none_or_several ->
          nil
      end
    end
  end

  # A machine some host agent reports, by the agents whose sources claim it.
  defp guest_agents(scope, guest_id) do
    sources =
      ResourceIdentifierClaim
      |> join(:inner, [claim], source in Source, on: source.id == claim.source_id)
      |> where([claim], claim.organization_id == ^scope.organization_id)
      |> where([claim], claim.resource_id == ^guest_id)
      |> where([_claim, source], source.kind == "host_agent")
      |> select([claim], claim.source_id)
      |> distinct(true)

    Agent
    |> where([agent], agent.organization_id == ^scope.organization_id)
    |> where([agent], agent.source_id in subquery(sources))
    |> Repo.all()
  end

  defp guest_macs(scope, guest_id) do
    Interface
    |> where([interface], interface.organization_id == ^scope.organization_id)
    |> where([interface], interface.resource_id == ^guest_id)
    |> where([interface], not is_nil(interface.mac_address))
    |> select([interface], interface.mac_address)
    |> Repo.all()
    |> MapSet.new()
  end

  defp uuid?(scope, guest_id) do
    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^scope.organization_id)
    |> where([identifier], identifier.resource_id == ^guest_id and identifier.kind == "dmi_uuid")
    |> Repo.exists?()
  end

  defp fresh_domains(scope, guest_id, now) do
    CollectorTargetResource
    |> where([member], member.organization_id == ^scope.organization_id)
    |> where([member], not is_nil(member.domain) and member.resource_id != ^guest_id)
    |> preload(:target)
    |> Repo.all()
    |> Enum.filter(
      &(CollectorTargetResource.present?(&1) and
          VmPlacements.fresh?(&1.target, &1.domain_reported_at, now))
    )
    |> Enum.map(&{&1, domain_macs(&1.domain)})
  end

  defp domain_macs(domain) do
    domain
    |> Map.get("interfaces", [])
    |> Enum.flat_map(&cast_mac(&1["mac_address"]))
    |> MapSet.new()
  end

  defp cast_mac(value) when is_binary(value) do
    case MacAddress.cast(value) do
      {:ok, mac} -> [mac]
      :error -> []
    end
  end

  defp cast_mac(_value), do: []

  defp open!(scope, guest_id, agents, vm_id, members, macs, now) do
    details = %{
      "vm_resource_id" => vm_id,
      "domain" => hd(members).domain["name"],
      "hypervisors" => members |> Enum.map(& &1.target.key) |> Enum.sort(),
      "mac_addresses" => macs |> Enum.map(&mac_string/1) |> Enum.sort()
    }

    message =
      "Its MAC addresses match libvirt domain #{details["domain"]}, but it reports no " <>
        "SMBIOS UUID to confirm they are the same machine"

    entries =
      Enum.map(agents, fn agent ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          resource_id: guest_id,
          agent_id: agent.id,
          kind: @kind,
          status: "open",
          message: message,
          details: details,
          last_observed_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(CollectorFinding, entries,
      on_conflict: {:replace, [:message, :details, :last_observed_at, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(organization_id, resource_id, agent_id, kind) WHERE status = 'open'"}
    )

    agent_ids = Enum.map(agents, & &1.id)

    resolve_where!(
      scope,
      guest_id,
      now,
      &where(&1, [finding], finding.agent_id not in ^agent_ids)
    )
  end

  defp resolve_where!(scope, guest_id, now, narrow) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^scope.organization_id)
    |> where([finding], finding.resource_id == ^guest_id)
    |> where([finding], finding.kind == @kind and finding.status == "open")
    |> narrow.()
    |> Repo.update_all(set: [status: "resolved", resolved_at: now, updated_at: now])
  end

  defp mac_string(%Postgrex.MACADDR{address: bytes}) do
    bytes
    |> Tuple.to_list()
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end
end
