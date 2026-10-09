defmodule Renga.IPAM do
  @moduledoc """
  IP address management (RFD 4) and the read models for the prefix views
  (RFD 8, "Prefixes").

  Prefix writes belong to owners and admins and run here so that a prefix's
  resource envelope and typed projection are created together, under one
  database-checked authorization, with a change event for Activity.

  VRFs (RFD 4, Phase 2) are the routing tables, with envelopes of their own;
  a prefix without one is in the global table, which has no record.

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
  alias Renga.Inventory.ResourceStore
  alias Renga.IPAM.AddressAssignment
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.ManagedAddress
  alias Renga.IPAM.PrefixTree
  alias Renga.IPAM.Vrf
  alias Renga.Repo
  alias Renga.Topology

  # Prefix fields an edit records in Activity, with the name each event uses.
  @prefix_event_fields [
    prefix: "prefix",
    vrf_id: "routing_table",
    status: "status",
    description: "description"
  ]

  @doc """
  Creates a prefix and its resource envelope. Owners and admins only.

  `attrs` are the typed prefix fields (`prefix`, `vrf_id`, `status`,
  `description`); a nil `vrf_id` is the global table. The envelope gets a
  stable generated name, so editing the CIDR later never renames it, and
  shows the CIDR, and the VRF when there is one, as its display name.
  Returns `{:error, :forbidden}` for anyone else, or the changeset when the
  CIDR is invalid or already exists in its routing table.
  """
  def create_prefix(%Scope{organization_id: organization_id} = scope, attrs) do
    Inventory.organization_management_transaction(scope, fn ->
      validation = Prefix.changeset(%Prefix{organization_id: organization_id}, attrs)

      # The resource does not exist yet, so its absence is the one error
      # expected here; anything else is the caller's input.
      if Keyword.delete(validation.errors, :resource_id) != [] do
        Repo.rollback(%{validation | action: :insert})
      end

      vrf = scoped_vrf(organization_id, Ecto.Changeset.get_field(validation, :vrf_id))
      label = prefix_label(Ecto.Changeset.get_field(validation, :prefix), vrf)

      resource =
        case ResourceStore.insert(organization_id, %{
               kind: "prefix",
               name: "prefix-" <> Ecto.UUID.generate(),
               display_name: label,
               lifecycle_state: "active"
             }) do
          {:ok, resource} -> resource
          {:error, changeset} -> Repo.rollback(changeset)
        end

      prefix =
        %Prefix{organization_id: organization_id, resource_id: resource.id}
        |> Prefix.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, prefix} -> prefix
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "created",
          field: "prefix",
          resource_id: resource.id,
          new_value: %{"value" => label}
        })

      %{prefix | resource: resource, vrf: vrf}
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  A changeset for the prefix create and edit forms. The envelope does not
  exist while a new prefix is being typed, so its absence is not an error.
  """
  def change_prefix(%Prefix{} = prefix, attrs \\ %{}) do
    changeset = Prefix.changeset(prefix, attrs)
    errors = Keyword.delete(changeset.errors, :resource_id)
    %{changeset | errors: errors, valid?: errors == []}
  end

  @doc """
  Changes a prefix's CIDR, routing table, status, or description. Owners and
  admins only. Each changed field writes an `updated` change event, and a
  new CIDR or table renames the envelope's display name.
  """
  def update_prefix(
        %Scope{organization_id: organization_id} = scope,
        %Prefix{id: id} = baseline,
        attrs
      ) do
    Inventory.organization_management_transaction(scope, fn ->
      current = lock_prefix!(organization_id, id)

      # A row lock serializes writes but cannot detect an outdated editing form.
      fields = Keyword.keys(@prefix_event_fields)

      if Map.take(current, fields) != Map.take(baseline, fields),
        do: Repo.rollback(:stale)

      updated =
        current
        |> Prefix.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} -> Repo.preload(updated, :vrf, force: true)
          {:error, changeset} -> Repo.rollback(changeset)
        end

      resource = rename_envelope(current.resource, prefix_label(updated.prefix, updated.vrf))
      record_prefix_changes(scope, resource.id, current, updated)

      %{updated | resource: resource}
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  Deletes a prefix with its envelope and VLAN links. Owners and admins only.

  Nothing else is deleted: addresses inside it, observed or managed, simply
  fall under the next containing prefix or none. A `deleted` change event
  naming the CIDR is written first; once the envelope is gone the event
  keeps the history with no resource to link to.
  """
  def delete_prefix(%Scope{organization_id: organization_id} = scope, %Prefix{id: id}) do
    Inventory.organization_management_transaction(scope, fn ->
      current = lock_prefix!(organization_id, id)

      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "deleted",
          field: "prefix",
          resource_id: current.resource_id,
          old_value: %{"value" => current.resource.display_name}
        })

      # The typed prefix and its VLAN links go with the envelope by cascade.
      Repo.delete!(current.resource)
      current
    end)
    |> Changes.broadcast(organization_id)
  end

  # The envelope's display name follows the CIDR and table; its stable
  # generated name never changes.
  defp rename_envelope(%{display_name: label} = resource, label), do: resource

  defp rename_envelope(resource, label) do
    case ResourceStore.update(resource, %{display_name: label}) do
      {:ok, resource} -> resource
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # One `updated` change event per changed field, with readable values.
  defp record_prefix_changes(scope, resource_id, current, updated) do
    for {field, name} <- @prefix_event_fields,
        Map.fetch!(current, field) != Map.fetch!(updated, field) do
      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "updated",
          field: name,
          resource_id: resource_id,
          old_value: event_value(field, current),
          new_value: event_value(field, updated)
        })
    end
  end

  defp lock_prefix!(organization_id, id) do
    Prefix
    |> where([prefix], prefix.organization_id == ^organization_id and prefix.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
    |> Repo.preload([:resource, :vrf])
  end

  # A routing-table event names the VRF and keeps its id, so a renamed VRF
  # or one literally called "Global" stays distinguishable from global (nil).
  defp event_value(:vrf_id, %Prefix{vrf: nil}), do: %{"value" => nil}
  defp event_value(:vrf_id, %Prefix{vrf: vrf}), do: %{"value" => vrf.name, "vrf_id" => vrf.id}
  defp event_value(:prefix, %Prefix{prefix: cidr}), do: %{"value" => Cidr.format(cidr)}
  defp event_value(field, %Prefix{} = prefix), do: %{"value" => Map.fetch!(prefix, field)}

  defp prefix_label(cidr, nil), do: Cidr.format(cidr)
  defp prefix_label(cidr, %Vrf{name: name}), do: "#{Cidr.format(cidr)} (#{name})"

  defp scoped_vrf(_organization_id, nil), do: nil

  # A share lock holds off a concurrent rename until the new prefix's label,
  # which names the VRF, is written.
  defp scoped_vrf(organization_id, vrf_id) do
    Vrf
    |> where([vrf], vrf.organization_id == ^organization_id and vrf.id == ^vrf_id)
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  @doc "The routing tables: `nil` for global, then every VRF by name."
  def list_routing_tables(%Scope{} = scope), do: [nil | list_vrfs(scope)]

  @doc "The organization's VRFs, by name."
  def list_vrfs(%Scope{organization_id: organization_id}) do
    Vrf
    |> where([vrf], vrf.organization_id == ^organization_id)
    |> order_by([vrf], asc: fragment("lower(?)", vrf.name))
    |> Repo.all()
  end

  @doc "Gets a VRF in the caller's organization."
  def get_vrf!(%Scope{organization_id: organization_id}, id) do
    Vrf
    |> where([vrf], vrf.organization_id == ^organization_id and vrf.id == ^id)
    |> preload(:resource)
    |> Repo.one!()
  end

  @doc "Finds a VRF by name, ignoring case, or nil."
  def get_vrf_by_name(%Scope{organization_id: organization_id}, name) when is_binary(name) do
    Vrf
    |> where([vrf], vrf.organization_id == ^organization_id)
    |> where([vrf], fragment("lower(?)", vrf.name) == ^String.downcase(String.trim(name)))
    |> Repo.one()
  end

  @doc "A changeset for the VRF forms; the envelope is not required yet."
  def change_vrf(%Vrf{} = vrf, attrs \\ %{}) do
    changeset = Vrf.changeset(vrf, attrs)
    errors = Keyword.delete(changeset.errors, :resource_id)
    %{changeset | errors: errors, valid?: errors == []}
  end

  @doc """
  Creates a VRF and its resource envelope. Owners and admins only. The
  envelope's display name is the VRF's name, and Activity records it.
  """
  def create_vrf(%Scope{organization_id: organization_id} = scope, attrs) do
    Inventory.organization_management_transaction(scope, fn ->
      validation = change_vrf(%Vrf{organization_id: organization_id}, attrs)
      unless validation.valid?, do: Repo.rollback(%{validation | action: :insert})

      name = Ecto.Changeset.get_field(validation, :name)

      resource =
        case ResourceStore.insert(organization_id, %{
               kind: "vrf",
               name: "vrf-" <> Ecto.UUID.generate(),
               display_name: name,
               lifecycle_state: "active"
             }) do
          {:ok, resource} -> resource
          {:error, changeset} -> Repo.rollback(changeset)
        end

      vrf =
        %Vrf{organization_id: organization_id, resource_id: resource.id}
        |> Vrf.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, vrf} -> vrf
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "created",
          field: "vrf",
          resource_id: resource.id,
          new_value: %{"value" => name}
        })

      %{vrf | resource: resource}
    end)
    |> Changes.broadcast(organization_id)
  end

  @vrf_event_fields [:name, :route_distinguisher, :status, :description]

  @doc """
  Changes a VRF. Owners and admins only. A rename relabels the VRF's
  envelope and every prefix in it, and each changed field is recorded.
  """
  def update_vrf(%Scope{organization_id: organization_id} = scope, %Vrf{id: id}, attrs) do
    Inventory.organization_management_transaction(scope, fn ->
      current = lock_vrf!(organization_id, id)

      updated =
        current
        |> Vrf.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      resource = rename_envelope(current.resource, updated.name)
      if updated.name != current.name, do: relabel_prefixes(updated)

      for field <- @vrf_event_fields,
          Map.fetch!(current, field) != Map.fetch!(updated, field) do
        {:ok, _event} =
          Inventory.create_change_event(scope, %{
            kind: "updated",
            field: Atom.to_string(field),
            resource_id: resource.id,
            old_value: %{"value" => Map.fetch!(current, field)},
            new_value: %{"value" => Map.fetch!(updated, field)}
          })
      end

      %{updated | resource: resource}
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  Deletes a VRF that holds no prefixes. Owners and admins only. A VRF with
  prefixes returns `{:error, :in_use}`: its prefixes must move or go first,
  since nothing should silently fall back into the global table.
  """
  def delete_vrf(%Scope{organization_id: organization_id} = scope, %Vrf{id: id}) do
    Inventory.organization_management_transaction(scope, fn ->
      current = lock_vrf!(organization_id, id)

      in_use? =
        Prefix
        |> where([prefix], prefix.organization_id == ^organization_id)
        |> where([prefix], prefix.vrf_id == ^current.id)
        |> Repo.exists?()

      if in_use?, do: Repo.rollback(:in_use)

      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "deleted",
          field: "vrf",
          resource_id: current.resource_id,
          old_value: %{"value" => current.name}
        })

      Repo.delete!(current.resource)
      current
    end)
    |> Changes.broadcast(organization_id)
  end

  defp lock_vrf!(organization_id, id) do
    Vrf
    |> where([vrf], vrf.organization_id == ^organization_id and vrf.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
    |> Repo.preload(:resource)
  end

  # Prefix envelopes show their table in the display name.
  defp relabel_prefixes(%Vrf{} = vrf) do
    Prefix
    |> where([prefix], prefix.organization_id == ^vrf.organization_id)
    |> where([prefix], prefix.vrf_id == ^vrf.id)
    |> preload(:resource)
    |> Repo.all()
    |> Enum.each(&rename_envelope(&1.resource, prefix_label(&1.prefix, vrf)))
  end

  @doc """
  One routing table's prefix trees as rows, `%{ipv4: rows, ipv6: rows}`.

  Each row has the tree `node`, its `depth`, its `usage` (see `usage/2`),
  the `vlans` it is linked to, its `counterparts` in the other family
  through those VLANs, and `single_stack?` when it is linked to a VLAN that
  carries no prefix of the other family.
  """
  def list_prefix_rows(%Scope{organization_id: organization_id} = scope, vrf_id) do
    prefixes =
      Prefix
      |> where([prefix], prefix.organization_id == ^organization_id)
      |> where_vrf(vrf_id)
      |> preload(:resource)
      |> Repo.all()

    trees = PrefixTree.build(prefixes)
    counts = address_counts(organization_id, Enum.map(prefixes, & &1.id))
    pairing = pairing(scope)

    Map.new([:ipv4, :ipv6], fn family ->
      rows =
        trees
        |> Map.get({vrf_id, family}, [])
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
    |> preload([:resource, :vrf])
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
      |> where_vrf(prefix.vrf_id)
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

  # One grouped containment join counts every prefix's distinct hosts at once,
  # so a host reported by several interfaces is used once.
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
         "CASE WHEN family(?) = 4 AND masklen(?) >= 22 THEN COUNT(DISTINCT host(?)) FILTER (WHERE NOT (masklen(?) <= 30 AND (host(?)::inet = host(network(?))::inet OR host(?)::inet = host(broadcast(?))::inet))) ELSE COUNT(DISTINCT host(?)) END",
         prefix.prefix,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.address,
         prefix.prefix,
         address.address
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

  defp where_vrf(query, nil), do: where(query, [prefix], is_nil(prefix.vrf_id))
  defp where_vrf(query, vrf_id), do: where(query, [prefix], prefix.vrf_id == ^vrf_id)
end
