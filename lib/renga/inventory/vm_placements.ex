defmodule Renga.Inventory.VmPlacements do
  @moduledoc """
  Where a VM is defined and where it runs (RFD 11, "Virtualization
  collection").

  Defined-on and active placement are different evidence. Every hypervisor
  that still reports a domain defines it there; only a fresh report of an
  active domain (running, idle, paused, or shutting down) claims it runs
  there. A claim is fresh while its hypervisor stream reached the hypervisor
  in the last 15 minutes (three default libvirt polls) and reported the
  domain active in the same window.

  A claim made before another hypervisor's run of active reports began is
  superseded by it, so a migrated VM moves once the destination reports it
  and before the source's next poll. Two claims that both continue past the
  other's start are competing: placement is `:ambiguous`. No fresh claim
  leaves it `:unknown`. Renga never picks a hypervisor, so privileged
  operations may act only on a `:placed` VM.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Repo

  @freshness_seconds 15 * 60

  @doc """
  The placement of a VM resource as of `now`:

    * `status` is `:placed`, `:ambiguous`, or `:unknown`
    * `hypervisor` is the one claim placing it, when `:placed`
    * `active` are the fresh claims still standing, newest first
    * `defined_on` are every hypervisor that still reports the domain

  Each claim has its stream's `target` (with `source`), the `domain` view,
  `active_since`, `last_reported_at`, and the hypervisor's `host_resource_id`
  when the stream reads the local hypervisor of a host Renga knows.
  """
  def placement(%Scope{} = scope, resource_id, now \\ Renga.Time.utc_now_ms()) do
    claims =
      scope
      |> list_members(resource_id)
      |> Enum.map(&claim(scope, &1))

    fresh = Enum.filter(claims, &fresh_active?(&1, now))
    standing = standing_hypervisors(fresh)

    active =
      fresh
      |> Enum.filter(&(hypervisor_key(&1) in standing))
      |> Enum.sort_by(& &1.active_since, {:desc, DateTime})

    {status, hypervisor} =
      case {standing, active} do
        {[], _active} -> {:unknown, nil}
        {[_hypervisor], [claim | _views]} -> {:placed, claim}
        _competing -> {:ambiguous, nil}
      end

    %{status: status, hypervisor: hypervisor, active: active, defined_on: claims}
  end

  defp list_members(scope, resource_id) do
    CollectorTargetResource
    |> where([member], member.organization_id == ^scope.organization_id)
    |> where([member], member.resource_id == ^resource_id)
    |> where([member], not is_nil(member.domain))
    |> order_by([member], asc: member.first_reported_at, asc: member.id)
    |> preload(target: [source: :installation_agent])
    |> Repo.all()
    |> Enum.filter(&CollectorTargetResource.present?/1)
  end

  # A member reported again without its domain after a withdrawal still
  # defines the VM there, but its old active run is over.
  defp claim(scope, member) do
    %{
      target: member.target,
      domain: member.domain,
      active_since: if(CollectorTargetResource.domain_current?(member), do: member.active_since),
      last_reported_at: member.domain_reported_at,
      host_resource_id: host_resource_id(scope, member.target)
    }
  end

  defp fresh_active?(%{active_since: nil}, _now), do: false

  defp fresh_active?(claim, now) do
    oldest = DateTime.add(now, -@freshness_seconds)

    claim.target.status == "reachable" and
      not is_nil(claim.target.last_reachable_at) and
      DateTime.compare(claim.target.last_reachable_at, oldest) != :lt and
      DateTime.compare(claim.last_reported_at, oldest) != :lt
  end

  # A hypervisor that last said "active" before another began saying so has
  # not said anything since the VM moved. Streams reading one hypervisor are
  # views of one run, from the earliest start to the latest report, so adding
  # a stream never looks like a migration.
  defp standing_hypervisors(claims) do
    runs =
      claims
      |> Enum.group_by(&hypervisor_key/1)
      |> Enum.map(fn {key, views} ->
        {key, Enum.min(Enum.map(views, & &1.active_since), DateTime),
         Enum.max(Enum.map(views, & &1.last_reported_at), DateTime)}
      end)

    for {key, _since, last_reported_at} <- runs,
        not Enum.any?(runs, fn {other, since, _last} ->
          other != key and DateTime.compare(last_reported_at, since) == :lt
        end),
        do: key
  end

  defp hypervisor_key(%{host_resource_id: nil, target: target}), do: {:target, target.id}
  defp hypervisor_key(%{host_resource_id: id}), do: {:host, id}

  # A stream reading the installation's own hypervisor runs on the host its
  # agent reports; a remote URI names some other machine.
  defp host_resource_id(scope, target) do
    with true <- local_uri?(target.key),
         %{source_id: host_source_id} when not is_nil(host_source_id) <-
           target.source.installation_agent,
         [resource_id] <- host_resources(scope, host_source_id) do
      resource_id
    else
      _unknown -> nil
    end
  end

  defp local_uri?(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(scheme) -> host in [nil, ""]
      _invalid -> false
    end
  end

  defp host_resources(scope, source_id) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^scope.organization_id)
    |> where([claim], claim.source_id == ^source_id)
    |> select([claim], claim.resource_id)
    |> distinct(true)
    |> Repo.all()
  end
end
