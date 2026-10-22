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

  Evaluation follows each reconciliation, as of the server's clock,
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

  The evaluation reads current evidence, so it is judged by the server's
  clock rather than the report's: an old report replayed late must not find
  evidence fresh that has since gone stale.
  """
  def refresh_after!(%Scope{} = scope, %Observation{} = observation, result) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(scope.organization_id)
      refresh_observation!(scope, observation, result, Renga.Time.utc_now_ms())
    end)
  end

  defp refresh_observation!(
         scope,
         %Observation{payload: %{"scope" => "hypervisor"}},
         {:ok, resources, _discovered?},
         now
       )
       when is_list(resources),
       do: refresh_all!(scope, now)

  defp refresh_observation!(
         scope,
         %Observation{} = observation,
         {:ok, %Resource{} = resource, _discovered?},
         now
       ) do
    if Inventory.get_source!(scope, observation.source_id).kind == "host_agent",
      do: refresh_guest!(scope, resource.id, now)
  end

  defp refresh_observation!(_scope, _observation, _result, _now), do: :ok

  @doc """
  Re-evaluates every machine the organization's domain evidence could
  concern as of `now`: those carrying a MAC of a domain still eligible, and
  those with an open finding. A hypervisor report can change what any
  guest matches, even one whose MACs it never named: an unreachable target
  ages out every claim it made, and a withdrawn clone leaves its twin
  unique. The evidence is loaded once for all of them.
  """
  def refresh_all!(%Scope{} = scope, now) do
    domains = eligible_domains(scope, now)
    macs = domains |> Enum.flat_map(fn {_member, macs} -> MapSet.to_list(macs) end) |> Enum.uniq()

    by_mac =
      Interface
      |> where([interface], interface.organization_id == ^scope.organization_id)
      |> where([interface], interface.mac_address in ^macs)
      |> present_interfaces()
      |> select([interface], interface.resource_id)

    by_finding =
      CollectorFinding
      |> where([finding], finding.organization_id == ^scope.organization_id)
      |> where([finding], finding.kind == @kind and finding.status == "open")
      |> select([finding], finding.resource_id)

    by_mac
    |> union(^by_finding)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.each(&refresh_guest!(scope, &1, now, domains))
  end

  @doc """
  Resolves the open findings whose evidence no longer singles out their VM
  as of `now`. Evidence also ages out with no report to say so, as when a
  hypervisor's agent stops, so `Renga.Inventory.SameMachineSweeper` calls
  this periodically. A finding that still stands is left as last observed:
  only a report is new evidence, and only a report opens a finding.
  """
  def expire!(%Scope{} = scope, now) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(scope.organization_id)
      domains = eligible_domains(scope, now)

      CollectorFinding
      |> where([finding], finding.organization_id == ^scope.organization_id)
      |> where([finding], finding.kind == @kind and finding.status == "open")
      |> select([finding], finding.resource_id)
      |> distinct(true)
      |> Repo.all()
      |> Enum.each(fn guest_id ->
        case guest_agents(scope, guest_id) != [] && candidate(scope, guest_id, domains) do
          {vm_id, _members, _macs} ->
            resolve_where!(
              scope,
              guest_id,
              now,
              &where(&1, [finding], fragment("?->>'vm_resource_id'", finding.details) != ^vm_id)
            )

          _gone ->
            resolve_where!(scope, guest_id, now, & &1)
        end
      end)
    end)
  end

  @doc "Opens, updates, or resolves the finding for one machine as of `now`."
  def refresh_guest!(%Scope{} = scope, guest_id, now, domains \\ nil) do
    case guest_agents(scope, guest_id) do
      [] ->
        resolve_where!(scope, guest_id, now, & &1)

      agents ->
        case candidate(scope, guest_id, domains || eligible_domains(scope, now)) do
          nil -> resolve_where!(scope, guest_id, now, & &1)
          {vm_id, members, macs} -> open!(scope, guest_id, agents, vm_id, members, macs, now)
        end
    end
  end

  defp candidate(scope, guest_id, domains) do
    guest_macs = guest_macs(scope, guest_id)

    if guest_macs == MapSet.new() or uuid?(scope, guest_id) do
      nil
    else
      matches =
        Enum.filter(domains, fn {member, macs} ->
          member.resource_id != guest_id and macs != MapSet.new() and
            MapSet.subset?(macs, guest_macs)
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

  # Only device-backed interfaces say which MACs the machine itself carries.
  # A virtual one may carry another's: a macvtap on a hypervisor host has
  # its guest's MAC, so the host would otherwise match its own VM.
  defp guest_macs(scope, guest_id) do
    Interface
    |> where([interface], interface.organization_id == ^scope.organization_id)
    |> where([interface], interface.resource_id == ^guest_id)
    |> where([interface], not is_nil(interface.mac_address) and interface.kind != "virtual")
    |> present_interfaces()
    |> select([interface], interface.mac_address)
    |> Repo.all()
    |> MapSet.new()
  end

  # An interface the machine stopped reporting keeps its row, and its MAC, as
  # not present; that MAC is no longer evidence the machine carries.
  defp present_interfaces(query),
    do: where(query, [interface], is_nil(interface.status) or interface.status != "not_present")

  # Firmware that never set a UUID reports all zeros or all ones, as many
  # unrelated machines do, so such a value does not identify the guest.
  @unset_uuids ~w(00000000-0000-0000-0000-000000000000 ffffffff-ffff-ffff-ffff-ffffffffffff)

  defp uuid?(scope, guest_id) do
    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^scope.organization_id)
    |> where([identifier], identifier.resource_id == ^guest_id and identifier.kind == "dmi_uuid")
    |> where([identifier], identifier.normalized_value not in ^@unset_uuids)
    |> Repo.exists?()
  end

  # Domains whose current, fresh view can single a machine out, with their MACs.
  defp eligible_domains(scope, now) do
    oldest = VmPlacements.oldest_fresh(now)

    CollectorTargetResource
    |> where([member], member.organization_id == ^scope.organization_id)
    |> where([member], not is_nil(member.domain) and member.domain_reported_at >= ^oldest)
    |> preload(:target)
    |> Repo.all()
    |> Enum.filter(
      &(CollectorTargetResource.present?(&1) and CollectorTargetResource.domain_current?(&1) and
          VmPlacements.fresh?(&1.target, &1.domain_reported_at, now))
    )
    |> Enum.map(&{&1, domain_macs(&1.domain)})
  end

  defp domain_macs(domain) do
    domain
    # The API accepts an explicit null for a domain without a device list.
    |> Map.get("interfaces")
    |> List.wrap()
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
      "hypervisors" =>
        members |> Enum.map(&display_uri(&1.target.key)) |> Enum.uniq() |> Enum.sort(),
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

    # A finding names one pairing, so a different VM resolves it and opens
    # its own rather than inheriting its history and any exception.
    resolve_where!(
      scope,
      guest_id,
      now,
      &where(&1, [finding], fragment("?->>'vm_resource_id'", finding.details) != ^vm_id)
    )

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

  # The Inbox shows every member these details. The bundled agent keeps
  # credentials out of libvirt URIs, but the API cannot promise another
  # client did, so only the scheme, host, and path are shown.
  defp display_uri(uri) do
    case URI.new(uri) do
      {:ok, uri} -> URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
      {:error, _part} -> "(unparseable URI)"
    end
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
