defmodule Renga.IPAM do
  @moduledoc """
  Read models for the prefix views (RFD 8, "Prefixes").

  Prefixes and addresses are stored by `Renga.Inventory`; VLAN links by
  `Renga.Topology`. This context arranges them per routing table and
  address family and chooses how each prefix is shown. Pairing an IPv4 and
  an IPv6 prefix derives from the optional prefix-to-VLAN relationship, so
  it needs no model of its own.

  Addresses carry no routing table, so a prefix's addresses are those inside
  it in any table.

  Observed addresses are normal and never findings. An owner or admin adopts
  one into managed state when it needs state of its own; a managed address
  that is no longer observed stays listed as managed, not seen.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Prefix
  alias Renga.IPAM.AddressAssignment
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.ManagedAddress
  alias Renga.IPAM.PrefixTree
  alias Renga.Repo
  alias Renga.Topology

  @doc "The routing tables in use: `nil` for global, then each VRF by name."
  def list_routing_tables(%Scope{organization_id: organization_id}) do
    vrfs =
      Prefix
      |> where([prefix], prefix.organization_id == ^organization_id and not is_nil(prefix.vrf))
      |> distinct(true)
      |> select([prefix], prefix.vrf)
      |> order_by([prefix], asc: prefix.vrf)
      |> Repo.all()

    [nil | vrfs]
  end

  @doc """
  One routing table's prefix trees as rows, `%{ipv4: rows, ipv6: rows}`.

  Each row has the tree `node`, its `depth`, its `usage` (see `usage/2`),
  the `vlans` it is linked to, its `counterparts` in the other family
  through those VLANs, and `single_stack?` when it is linked to a VLAN that
  carries no prefix of the other family.
  """
  def list_prefix_rows(%Scope{organization_id: organization_id} = scope, vrf) do
    prefixes =
      Prefix
      |> where([prefix], prefix.organization_id == ^organization_id)
      |> where_vrf(vrf)
      |> preload(:resource)
      |> Repo.all()

    trees = PrefixTree.build(prefixes)
    counts = address_counts(organization_id, Enum.map(prefixes, & &1.id))
    pairing = pairing(scope)

    Map.new([:ipv4, :ipv6], fn family ->
      rows =
        trees
        |> Map.get({vrf, family}, [])
        |> PrefixTree.flatten()
        |> Enum.map(fn {node, depth} ->
          node
          |> row(depth, Map.get(counts, node.prefix.id, 0))
          |> Map.merge(Map.get(pairing, node.prefix.id, %{vlans: [], counterparts: []}))
          |> then(&Map.put(&1, :single_stack?, &1.vlans != [] and &1.counterparts == []))
        end)

      {family, rows}
    end)
  end

  @doc "Gets a prefix in the caller's organization."
  def get_prefix!(%Scope{organization_id: organization_id}, id) do
    Prefix
    |> where([prefix], prefix.organization_id == ^organization_id and prefix.id == ^id)
    |> preload(:resource)
    |> Repo.one!()
  end

  @doc """
  Everything a prefix's page shows: its `node` (with the prefixes inside it
  in its routing table), `ancestors` from the outermost, the view `mode`
  and that mode's data, the linked `vlans` and their other-family
  `counterparts`.

  Addresses are listed for leaves only; a container shows its child space.
  """
  def prefix_view(%Scope{organization_id: organization_id} = scope, %Prefix{} = prefix) do
    related =
      Prefix
      |> where([other], other.organization_id == ^organization_id)
      |> where_vrf(prefix.vrf)
      |> where(
        [other],
        fragment("? << ?", other.prefix, type(^prefix.prefix, Renga.Types.Cidr)) or
          fragment("? >> ?", other.prefix, type(^prefix.prefix, Renga.Types.Cidr))
      )
      |> preload(:resource)
      |> Repo.all()

    {inside, ancestors} = Enum.split_with(related, &Cidr.contains?(prefix.prefix, &1.prefix))
    [node] = PrefixTree.build([prefix | inside]) |> Map.values() |> hd()
    mode = PrefixTree.mode(node)
    pairing = Map.get(pairing(scope), prefix.id, %{vlans: [], counterparts: []})

    %{
      node: node,
      ancestors: Enum.sort_by(ancestors, &Cidr.length(&1.prefix)),
      mode: mode,
      vlans: pairing.vlans,
      counterparts: pairing.counterparts
    }
    |> Map.merge(mode_data(organization_id, mode, node))
  end

  @doc """
  What "used" means for a prefix: children allocated for a container,
  host utilization for a small IPv4 leaf, an address count otherwise.
  """
  def usage(node, address_count) do
    case PrefixTree.mode(node) do
      :container ->
        map = PrefixTree.space_map(node)
        %{kind: :children, allocated: map.allocated, total: map.total, level: map.level}

      :address_map ->
        usable = node.prefix.prefix |> Cidr.size() |> usable_hosts(node.prefix.prefix)

        %{
          kind: :percent,
          used: address_count,
          usable: usable,
          percent: if(usable > 0, do: round(address_count / usable * 100), else: 0)
        }

      :address_table ->
        %{kind: :count, count: address_count}
    end
  end

  defp row(node, depth, address_count) do
    %{node: node, depth: depth, usage: usage(node, address_count)}
  end

  defp usable_hosts(size, cidr) do
    if Cidr.length(cidr) <= 30, do: size - 2, else: size
  end

  defp mode_data(_organization_id, :container, node), do: %{space: PrefixTree.space_map(node)}

  defp mode_data(organization_id, :address_map, node) do
    observed = addresses_in(organization_id, node.prefix.prefix)
    entries = address_entries(organization_id, node.prefix.prefix, observed)
    %{addresses: entries, address_map: PrefixTree.address_map(node, observed, entries)}
  end

  defp mode_data(organization_id, :address_table, node) do
    observed = addresses_in(organization_id, node.prefix.prefix)
    %{addresses: address_entries(organization_id, node.prefix.prefix, observed)}
  end

  # One entry per address: observed ones (managed or not) and managed ones
  # no collector reports any more, in address order.
  defp address_entries(organization_id, cidr, observed) do
    managed = Map.new(managed_in(organization_id, cidr), &{Cidr.to_integer(&1.address), &1})
    seen = MapSet.new(observed, &Cidr.to_integer(&1.address))

    observed_entries =
      Enum.map(observed, fn address ->
        %{
          inet: address.address,
          address: address,
          managed: Map.get(managed, Cidr.to_integer(address.address)),
          method: AddressAssignment.method(address),
          temporary?: AddressAssignment.temporary?(address)
        }
      end)

    unseen =
      managed
      |> Enum.reject(fn {value, _managed} -> MapSet.member?(seen, value) end)
      |> Enum.map(fn {_value, managed} ->
        %{inet: managed.address, address: nil, managed: managed, method: nil, temporary?: false}
      end)

    Enum.sort_by(observed_entries ++ unseen, &Cidr.to_integer(&1.inet))
  end

  defp managed_in(organization_id, cidr) do
    ManagedAddress
    |> where([managed], managed.organization_id == ^organization_id)
    |> where([managed], fragment("? <<= ?", managed.address, type(^cidr, Renga.Types.Cidr)))
    |> preload(interface: :resource)
    |> Repo.all()
  end

  @doc """
  Adopts an observed address into managed state, remembering the interface
  it was seen on. Owners and admins only.
  """
  def adopt_address(%Scope{organization_id: organization_id} = scope, address_id, attrs \\ %{}) do
    if Inventory.organization_manager?(scope) do
      address =
        Address
        |> where(
          [address],
          address.organization_id == ^organization_id and address.id == ^address_id
        )
        |> where(
          [address],
          fragment("(?->'present') IS DISTINCT FROM 'false'::jsonb", address.metadata)
        )
        |> Repo.one!()

      %ManagedAddress{
        organization_id: organization_id,
        address: %{address.address | netmask: Cidr.bits(Cidr.family(address.address))},
        interface_id: address.interface_id,
        adopted_by_id: scope.user.id
      }
      |> ManagedAddress.changeset(attrs)
      |> Repo.insert()
      |> Changes.broadcast(organization_id)
    else
      {:error, :forbidden}
    end
  end

  @doc "Releases a managed address back to observed-only. Owners and admins only."
  def release_address(%Scope{organization_id: organization_id} = scope, managed_id) do
    if Inventory.organization_manager?(scope) do
      ManagedAddress
      |> where(
        [managed],
        managed.organization_id == ^organization_id and managed.id == ^managed_id
      )
      |> Repo.one!()
      |> Repo.delete()
      |> Changes.broadcast(organization_id)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Dual-stack coverage for a VLAN: which devices have addresses in its IPv4
  prefixes, its IPv6 prefixes, or both.

  `nil` when the VLAN does not carry both families, because coverage only
  means something once both are planned.
  """
  def vlan_dual_stack(%Scope{organization_id: organization_id} = scope, vlan_id) do
    prefixes = Topology.list_vlan_prefixes(scope, vlan_id)
    {ipv4, ipv6} = Enum.split_with(prefixes, &(Cidr.family(&1.prefix) == :ipv4))

    if ipv4 != [] and ipv6 != [] do
      v4 = devices_in(organization_id, ipv4)
      v6 = devices_in(organization_id, ipv6)
      both = v4 |> Map.take(Map.keys(v6)) |> Map.values()

      %{
        both: sort_devices(both),
        missing_ipv6: v4 |> Map.drop(Map.keys(v6)) |> Map.values() |> sort_devices(),
        missing_ipv4: v6 |> Map.drop(Map.keys(v4)) |> Map.values() |> sort_devices(),
        total: v4 |> Map.merge(v6) |> map_size()
      }
    end
  end

  # Devices with an address inside any of `prefixes`, keyed by id.
  defp devices_in(organization_id, prefixes) do
    cidrs = Enum.map(prefixes, & &1.prefix)

    Address
    |> where([address], address.organization_id == ^organization_id)
    |> where(
      [address],
      fragment("(?->'present') IS DISTINCT FROM 'false'::jsonb", address.metadata)
    )
    |> where(
      [address],
      fragment(
        "host(?)::inet <<= ANY(?)",
        address.address,
        type(^cidrs, {:array, Renga.Types.Cidr})
      )
    )
    |> join(:inner, [address], resource in assoc(address, :resource))
    |> select([_address, resource], resource)
    |> distinct(true)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp sort_devices(devices), do: Enum.sort_by(devices, & &1.name)

  defp addresses_in(organization_id, cidr) do
    Address
    |> where([address], address.organization_id == ^organization_id)
    |> where(
      [address],
      fragment("(?->'present') IS DISTINCT FROM 'false'::jsonb", address.metadata)
    )
    |> where(
      [address],
      fragment("host(?)::inet <<= ?", address.address, type(^cidr, Renga.Types.Cidr))
    )
    # Use the winning presence observation, never another source's historical hints.
    |> join(:left, [address], evidence in AddressEvidence,
      on:
        evidence.organization_id == address.organization_id and evidence.address_id == address.id and
          fragment(
            "?::text = ?->'presence_owner'->>'observation_id'",
            evidence.observation_id,
            address.metadata
          )
    )
    |> select_merge([address, evidence], %{
      metadata: fragment("COALESCE(?, '{}'::jsonb) || ?", evidence.metadata, address.metadata)
    })
    |> order_by([address], asc: address.address)
    |> preload(interface: :resource)
    |> Repo.all()
  end

  # One grouped containment join counts every prefix's addresses at once.
  defp address_counts(_organization_id, []), do: %{}

  defp address_counts(organization_id, prefix_ids) do
    Prefix
    |> where([prefix], prefix.id in ^prefix_ids)
    |> join(:inner, [prefix], address in Address,
      on:
        address.organization_id == ^organization_id and
          fragment("(?->'present') IS DISTINCT FROM 'false'::jsonb", address.metadata) and
          fragment("host(?)::inet <<= ?", address.address, prefix.prefix)
    )
    |> group_by([prefix], prefix.id)
    |> select(
      [prefix, address],
      {prefix.id,
       fragment(
         "CASE WHEN family(?) = 4 AND masklen(?) >= 22 THEN COUNT(DISTINCT host(?)) FILTER (WHERE NOT (masklen(?) <= 30 AND (host(?)::inet = host(network(?))::inet OR host(?)::inet = host(broadcast(?))::inet))) ELSE COUNT(?) END",
         prefix.prefix,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.id
       )}
    )
    |> Repo.all()
    |> Map.new()
  end

  # For each VLAN-linked prefix: its VLANs and the prefixes of the other
  # family that the same VLANs carry.
  defp pairing(scope) do
    relationships = Topology.list_prefix_vlan_relationships(scope)
    vlans = scope |> Topology.list_vlans() |> Map.new(&{&1.id, &1})
    by_vlan = Enum.group_by(relationships, & &1.vlan_id, & &1.prefix)

    relationships
    |> Enum.group_by(& &1.prefix_id)
    |> Map.new(fn {prefix_id, links} ->
      prefix = hd(links).prefix
      family = Cidr.family(prefix.prefix)
      vlan_ids = Enum.map(links, & &1.vlan_id)

      counterparts =
        vlan_ids
        |> Enum.flat_map(&Map.get(by_vlan, &1, []))
        |> Enum.reject(&(Cidr.family(&1.prefix) == family))
        |> Enum.uniq_by(& &1.id)

      {prefix_id,
       %{
         vlans: vlan_ids |> Enum.map(&Map.get(vlans, &1)) |> Enum.reject(&is_nil/1),
         counterparts: counterparts
       }}
    end)
  end

  defp where_vrf(query, nil), do: where(query, [prefix], is_nil(prefix.vrf))
  defp where_vrf(query, vrf), do: where(query, [prefix], prefix.vrf == ^vrf)
end
