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

  Utilization is namespace-local (RFD 4, "Utilization"). Collectors do not
  report routing domains yet, so every observed address is in the global
  table and counts toward global prefixes only. Managed addresses carry
  their own routing table and count there, so a VRF's prefixes are occupied
  by the addresses managed in that VRF.

  Observed addresses are normal: they become findings only in the conditions
  `Renga.IPAM.AddressFindings` reconciles, such as an unmanaged address in a
  strict prefix, and every prefix and address write here reconciles those
  findings before it commits. An owner or admin adopts one into a managed
  `ip_address` (RFD 4, Phase 3) when it needs state of its own; a managed
  address that is no longer observed stays listed as managed, not seen.
  Release retires the address instead of deleting it.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Prefix
  alias Renga.Inventory.ResourceStore
  alias Renga.IPAM.AddressAssignment
  alias Renga.IPAM.AddressFindings
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.IpAddress
  alias Renga.IPAM.IpAddressAssignment
  alias Renga.IPAM.PrefixTree
  alias Renga.IPAM.Vrf
  alias Renga.Repo
  alias Renga.Topology

  # Prefix fields an edit records in Activity, with the name each event uses.
  @prefix_event_fields [
    prefix: "prefix",
    vrf_id: "routing_table",
    status: "status",
    description: "description",
    strict: "address_policy"
  ]

  @doc """
  Creates a prefix and its resource envelope. Owners and admins only.

  `attrs` are the typed prefix fields (`prefix`, `vrf_id`, `status`,
  `description`, `strict`); a nil `vrf_id` is the global table. The envelope gets a
  stable generated name, so editing the CIDR later never renames it, and
  shows the CIDR, and the VRF when there is one, as its display name.
  Returns `{:error, :forbidden}` for anyone else, or the changeset when the
  CIDR is invalid or already exists in its routing table.
  """
  def create_prefix(%Scope{organization_id: organization_id} = scope, attrs) do
    ipam_transaction(scope, fn ->
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
  Changes a prefix's CIDR, routing table, status, description, or address
  policy. Owners and admins only. Each changed field writes an `updated`
  change event, and a new CIDR or table renames the envelope's display name.
  """
  def update_prefix(
        %Scope{organization_id: organization_id} = scope,
        %Prefix{id: id} = baseline,
        attrs
      ) do
    ipam_transaction(scope, fn ->
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
    ipam_transaction(scope, fn ->
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

  # Every prefix and address write changes which address findings should be
  # open, so each one reconciles them before it commits (RFD 4, "Findings").
  defp ipam_transaction(%Scope{organization_id: organization_id} = scope, mutation) do
    Inventory.organization_management_transaction(scope, fn ->
      case mutation.() do
        {:error, _reason} = error ->
          error

        result ->
          {:ok, :ok} = AddressFindings.reconcile(organization_id)
          result
      end
    end)
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
  defp event_value(:strict, %Prefix{strict: true}), do: %{"value" => "strict"}
  defp event_value(:strict, %Prefix{strict: false}), do: %{"value" => "normal"}
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

  `baseline` is the VRF as the editor last read it; if any recorded field
  has changed since, the edit returns `{:error, :stale}` and writes nothing.
  """
  def update_vrf(%Scope{organization_id: organization_id} = scope, %Vrf{id: id} = baseline, attrs) do
    Inventory.organization_management_transaction(scope, fn ->
      current = lock_vrf!(organization_id, id)

      if Map.take(current, @vrf_event_fields) != Map.take(baseline, @vrf_event_fields),
        do: Repo.rollback(:stale)

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
  Prefix counts per routing table, keyed by `vrf_id` with `nil` for the
  global table. Tables without prefixes are absent.
  """
  def prefix_counts(%Scope{organization_id: organization_id}) do
    Prefix
    |> where([prefix], prefix.organization_id == ^organization_id)
    |> group_by([prefix], prefix.vrf_id)
    |> select([prefix], {prefix.vrf_id, count(prefix.id)})
    |> Repo.all()
    |> Map.new()
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
    |> Map.put(:addresses_observable?, is_nil(prefix.vrf_id))
  end

  @doc """
  What "used" means for a prefix, by its status (RFD 4, "Prefixes"): a
  `container` is measured by the space its child prefixes cover, even
  before it has any; every other prefix by its occupied hosts, as host
  utilization for a small IPv4 prefix and an address count otherwise.

  How a prefix is *shown* still follows its children (`PrefixTree.mode/1`),
  so an active prefix with children keeps its child-space map while its
  usage counts hosts.
  """
  def usage(%{prefix: %{status: "container"}} = node, _address_count) do
    space = PrefixTree.child_space(node)
    %{kind: :children, allocated: space.allocated, total: space.total, level: space.level}
  end

  def usage(node, address_count) do
    cidr = node.prefix.prefix

    case PrefixTree.host_mode(cidr) do
      :address_map ->
        usable = cidr |> Cidr.size() |> usable_hosts(cidr)

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
    observed = addresses_in(organization_id, node.prefix)
    entries = address_entries(organization_id, node.prefix, observed)
    %{addresses: entries, address_map: PrefixTree.address_map(node, observed, entries)}
  end

  defp mode_data(organization_id, :address_table, node) do
    observed = addresses_in(organization_id, node.prefix)
    %{addresses: address_entries(organization_id, node.prefix, observed)}
  end

  # One entry per address: observed ones (managed or not) and managed ones
  # no collector reports any more, in address order.
  defp address_entries(organization_id, prefix, observed) do
    managed = Map.new(managed_in(organization_id, prefix), &{Cidr.to_integer(&1.address), &1})
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

  # Current managed intent in the prefix's routing table: a retired address
  # is history and no longer occupies anything. Identity is the host, so an
  # address managed with a wider intended mask still sits in the prefix.
  defp managed_in(organization_id, %Prefix{prefix: cidr, vrf_id: vrf_id}) do
    IpAddress
    |> where([ip], ip.organization_id == ^organization_id)
    |> where_vrf(vrf_id)
    |> where(
      [ip],
      fragment("host(?)::inet <<= ?", ip.address, type(^cidr, Renga.Types.Cidr))
    )
    |> join(:inner, [ip], resource in assoc(ip, :resource))
    |> where([_ip, resource], resource.lifecycle_state == "active")
    |> preload(assignments: [interface: :resource])
    |> Repo.all()
  end

  @doc """
  Adopts an observed address into managed state. Owners and admins only,
  re-checked in the database.

  In one transaction it creates an allocated `ip_address` in the observed
  address's routing table (global until collectors report routing domains)
  with the observed mask, takes the management mode from the assignment
  method where it is known, and assigns it to the interface it was seen on.
  A released address with the same host is reactivated rather than created
  again, so its history stays one record. `attrs` may carry a description
  or DNS name.

  Returns `{:error, changeset}` when the host is already managed there.
  """
  def adopt_address(%Scope{organization_id: organization_id} = scope, address_id, attrs \\ %{}) do
    ipam_transaction(scope, fn ->
      observed = observed_address!(organization_id, address_id)
      interface = Repo.preload(observed, interface: :resource).interface
      attrs = Map.take(attrs, [:description, :dns_name, "description", "dns_name"])

      # Adoption establishes new current intent, so a released shared role
      # does not come back with the address.
      intent = %{
        address: observed.address,
        vrf_id: nil,
        allocation_state: "allocated",
        management_mode: management_mode(observed),
        role: "ordinary",
        adopted_by_id: scope.user.id
      }

      ip_address =
        case lock_managed_host(organization_id, nil, observed.address) do
          nil ->
            insert_ip_address(scope, intent, attrs)

          %IpAddress{resource: %{lifecycle_state: "retired"}} = retired ->
            reactivate(scope, retired, intent, attrs)

          current ->
            Repo.rollback(already_managed(current))
        end

      assign!(scope, ip_address, interface)
      Repo.preload(ip_address, [assignments: [interface: :resource]], force: true)
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  Releases a managed address back to observed-only. Owners and admins only.

  Every current assignment ends and the envelope is retired rather than
  deleted, so Activity keeps its history and a later adoption reactivates
  the same record. Releasing an already released address changes nothing.
  """
  def release_address(%Scope{organization_id: organization_id} = scope, ip_address_id) do
    ipam_transaction(scope, fn ->
      current = lock_ip_address!(organization_id, ip_address_id)

      if current.resource.lifecycle_state == "retired" do
        current
      else
        Enum.each(current.assignments, &unassign!(scope, current, &1))
        resource = set_lifecycle!(scope, current.resource, "retired")
        %{current | resource: resource, assignments: []}
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  An observed address and whether its host is managed in the global table,
  where every observed address is until collectors report routing domains.
  Nil when the id is malformed or names no address in the organization.
  Adoption requests use it for their value and to confirm the address.
  """
  def observed_address(%Scope{organization_id: organization_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Address{} = address <- Repo.get_by(Address, organization_id: organization_id, id: id) do
      managed? =
        IpAddress
        |> join(:inner, [ip], resource in assoc(ip, :resource))
        |> where([ip], ip.organization_id == ^organization_id and is_nil(ip.vrf_id))
        |> where([ip], fragment("host(?)::inet = host(?)::inet", ip.address, ^address.address))
        |> where([_ip, resource], resource.lifecycle_state != "retired")
        |> Repo.exists?()

      %{address: address, managed?: managed?}
    else
      _missing -> nil
    end
  end

  @address_list_limit 200

  @doc """
  Managed addresses for the address list, in address order, at most
  #{@address_list_limit}.

  `filters` (string keys, as the page sends them):

    * `"q"` - an address or CIDR matches the hosts inside it; any other text
      matches the address, DNS name, description, or an assigned interface
      or device name;
    * `"vrf"` - a VRF id, `"global"`, or absent for every routing table;
    * `"released"` - `"true"` to include released addresses, which are
      otherwise history and left out.
  """
  def list_ip_addresses(%Scope{organization_id: organization_id}, filters \\ %{}) do
    IpAddress
    |> where([ip], ip.organization_id == ^organization_id)
    |> join(:inner, [ip], resource in assoc(ip, :resource))
    |> filter_released(filters["released"])
    |> filter_table(filters["vrf"])
    |> filter_search(String.trim(filters["q"] || ""))
    |> order_by([ip],
      asc: fragment("family(?)", ip.address),
      asc: fragment("host(?)::inet", ip.address)
    )
    |> limit(@address_list_limit)
    |> preload([ip, resource], resource: resource)
    |> preload([:vrf, assignments: [interface: :resource]])
    |> Repo.all()
  end

  @doc "The most addresses `list_ip_addresses/2` returns."
  def address_list_limit, do: @address_list_limit

  defp filter_released(query, "true"), do: query

  defp filter_released(query, _),
    do: where(query, [_ip, resource], resource.lifecycle_state == "active")

  defp filter_table(query, "global"), do: where(query, [ip], is_nil(ip.vrf_id))

  defp filter_table(query, vrf_id) when is_binary(vrf_id) and vrf_id != "" do
    case Ecto.UUID.cast(vrf_id) do
      {:ok, id} -> where(query, [ip], ip.vrf_id == ^id)
      :error -> where(query, [_ip], false)
    end
  end

  defp filter_table(query, _all), do: query

  defp filter_search(query, ""), do: query

  defp filter_search(query, text) do
    case Renga.Types.Inet.cast(text) do
      {:ok, inet} ->
        where(
          query,
          [ip],
          fragment("host(?)::inet <<= network(?)", ip.address, type(^inet, Renga.Types.Inet))
        )

      :error ->
        pattern = "%" <> escape_like(text) <> "%"

        assigned =
          from assignment in IpAddressAssignment,
            join: interface in assoc(assignment, :interface),
            join: resource in assoc(interface, :resource),
            where: ilike(interface.name, ^pattern) or ilike(resource.name, ^pattern),
            select: assignment.ip_address_id

        where(
          query,
          [ip],
          ilike(fragment("host(?)", ip.address), ^pattern) or ilike(ip.dns_name, ^pattern) or
            ilike(ip.description, ^pattern) or ip.id in subquery(assigned)
        )
    end
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  @doc "Gets a managed address in the caller's organization, released or not."
  def get_ip_address!(%Scope{organization_id: organization_id}, id) do
    IpAddress
    |> where([ip], ip.organization_id == ^organization_id and ip.id == ^id)
    |> preload([:resource, :vrf, assignments: [interface: :resource]])
    |> Repo.one!()
  end

  @doc """
  Interfaces an address could be assigned to, matching `text` against the
  interface or device name, at most `limit`, by device then interface.
  """
  def assignable_interfaces(%Scope{organization_id: organization_id}, text, limit \\ 8) do
    case String.trim(text || "") do
      "" ->
        []

      text ->
        pattern = "%" <> escape_like(text) <> "%"

        Interface
        |> where([interface], interface.organization_id == ^organization_id)
        |> join(:inner, [interface], resource in assoc(interface, :resource))
        |> where(
          [interface, resource],
          ilike(interface.name, ^pattern) or ilike(resource.name, ^pattern)
        )
        |> order_by([interface, resource], asc: resource.name, asc: interface.name)
        |> limit(^limit)
        |> preload([_interface, resource], resource: resource)
        |> Repo.all()
    end
  end

  @shared_roles ~w(vip anycast vrrp hsrp glbp carp)
  @editable_ip_address_fields [
    :allocation_state,
    :management_mode,
    :role,
    :dns_name,
    :description
  ]

  @doc """
  Whether a role lets one address be assigned to several interfaces: a VIP,
  anycast, or first-hop redundancy address. Every other role is one
  interface at most.
  """
  def shared_role?(role), do: role in @shared_roles

  @doc "A changeset for the address forms; the envelope is not required yet."
  def change_ip_address(%IpAddress{} = ip_address, attrs \\ %{}) do
    changeset = IpAddress.changeset(ip_address, attrs)
    errors = Keyword.delete(changeset.errors, :resource_id)
    %{changeset | errors: errors, valid?: errors == []}
  end

  @doc """
  Reserves (by default) or allocates a managed address by hand, in the global
  table or a VRF, with no observation needed. Owners and admins only.

  A released address with the same host in that routing table is
  reactivated with this new intent rather than created again. Returns the
  changeset when the host is already managed there or the input is invalid.
  """
  def create_ip_address(%Scope{organization_id: organization_id} = scope, attrs) do
    ipam_transaction(scope, fn ->
      validation =
        change_ip_address(
          %IpAddress{organization_id: organization_id, allocation_state: "reserved"},
          attrs
        )

      unless validation.valid?, do: Repo.rollback(%{validation | action: :insert})

      intent =
        Map.new([:address, :vrf_id, :allocation_state, :management_mode, :role], fn field ->
          {field, Ecto.Changeset.get_field(validation, field)}
        end)

      notes = Map.take(attrs, [:description, :dns_name, "description", "dns_name"])

      ip_address =
        case lock_managed_host(organization_id, intent.vrf_id, intent.address) do
          nil ->
            insert_ip_address(scope, intent, notes)

          %IpAddress{resource: %{lifecycle_state: "retired"}} = retired ->
            reactivate(scope, retired, intent, notes)

          _current ->
            Repo.rollback(already_managed(validation))
        end

      Repo.preload(ip_address, [:vrf, assignments: [interface: :resource]], force: true)
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  Changes a managed address's allocation state, management mode, role, DNS
  name, or description. Owners and admins only; each change is recorded.

  The address and routing table are its identity and do not change here.
  `baseline` is the address as the editor last read it, so an edit made
  meanwhile returns `{:error, :stale}`. A released address returns
  `{:error, :retired}`. An address shared by several interfaces keeps a
  shared role until all but one assignment is removed.
  """
  def update_ip_address(
        %Scope{organization_id: organization_id} = scope,
        %IpAddress{id: id} = baseline,
        attrs
      ) do
    ipam_transaction(scope, fn ->
      current = lock_ip_address!(organization_id, id)
      if current.resource.lifecycle_state == "retired", do: Repo.rollback(:retired)

      if Map.take(current, @editable_ip_address_fields) !=
           Map.take(baseline, @editable_ip_address_fields),
         do: Repo.rollback(:stale)

      updated =
        current
        |> IpAddress.changeset(Map.take(attrs, editable_keys()))
        |> keep_shared_role(length(current.assignments))
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      record_ip_address_changes(scope, current.resource_id, current, updated)
      %{updated | resource: current.resource, vrf: current.vrf, assignments: current.assignments}
    end)
    |> Changes.broadcast(organization_id)
  end

  defp editable_keys,
    do: @editable_ip_address_fields ++ Enum.map(@editable_ip_address_fields, &Atom.to_string/1)

  # Several interfaces share this address, so only a shared role fits it.
  defp keep_shared_role(changeset, assignments) when assignments > 1 do
    if shared_role?(Ecto.Changeset.get_field(changeset, :role)),
      do: changeset,
      else:
        Ecto.Changeset.add_error(
          changeset,
          :role,
          "is shared by #{assignments} interfaces; remove all but one assignment first"
        )
  end

  defp keep_shared_role(changeset, _assignments), do: changeset

  @doc """
  Assigns a managed address to an interface in the same organization.
  Owners and admins only.

  The address row is locked, so concurrent assignments are decided one at a
  time: an address with an ordinary role takes one interface, and only a
  shared role (`shared_role?/1`) takes more. A released address returns
  `{:error, :retired}`; a refused assignment returns its changeset.
  """
  def assign_address(
        %Scope{organization_id: organization_id} = scope,
        ip_address_id,
        interface_id
      ) do
    ipam_transaction(scope, fn ->
      current = lock_ip_address!(organization_id, ip_address_id)
      if current.resource.lifecycle_state == "retired", do: Repo.rollback(:retired)

      interface =
        Interface
        |> where([interface], interface.organization_id == ^organization_id)
        |> where([interface], interface.id == ^interface_id)
        |> preload(:resource)
        |> Repo.one!()

      cond do
        Enum.any?(current.assignments, &(&1.interface_id == interface.id)) ->
          Repo.rollback(assignment_error("already has this address"))

        current.assignments != [] and not shared_role?(current.role) ->
          Repo.rollback(
            assignment_error(
              "is not available: the address is already assigned, and only a VIP, " <>
                "anycast, or first-hop redundancy role is shared"
            )
          )

        true ->
          assign!(scope, current, interface)
      end

      Repo.preload(current, [assignments: [interface: :resource]], force: true)
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  Removes one assignment, leaving the managed address and any other
  assignments in place. Owners and admins only, recorded in Activity.
  """
  def unassign_address(%Scope{organization_id: organization_id} = scope, assignment_id) do
    ipam_transaction(scope, fn ->
      %{ip_address_id: ip_address_id} =
        IpAddressAssignment
        |> where([a], a.organization_id == ^organization_id and a.id == ^assignment_id)
        |> Repo.one!()

      # Lock the address first, as assignment does, then act on the row as
      # it stands now.
      current = lock_ip_address!(organization_id, ip_address_id)

      case Enum.find(current.assignments, &(&1.id == assignment_id)) do
        nil -> Repo.rollback(:not_found)
        assignment -> unassign!(scope, current, assignment)
      end

      Repo.preload(current, [assignments: [interface: :resource]], force: true)
    end)
    |> Changes.broadcast(organization_id)
  end

  defp assignment_error(message) do
    %IpAddressAssignment{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:interface_id, message)
    |> Map.put(:action, :insert)
  end

  defp observed_address!(organization_id, address_id) do
    observed =
      Address
      |> where(
        [address],
        address.organization_id == ^organization_id and address.id == ^address_id
      )
      |> where(
        [address],
        fragment("(?->'present') IS DISTINCT FROM 'false'::jsonb", address.metadata)
      )
      |> lock("FOR UPDATE")
      |> Repo.one!()

    # Match the prefix view's winning evidence, not another collector's hints.
    if observation_id = get_in(observed.metadata, ["presence_owner", "observation_id"]) do
      evidence =
        Repo.get_by(AddressEvidence,
          organization_id: organization_id,
          address_id: observed.id,
          observation_id: observation_id,
          address: observed.address
        )

      metadata =
        if evidence, do: Map.merge(evidence.metadata, observed.metadata), else: observed.metadata

      %{observed | metadata: metadata}
    else
      observed
    end
  end

  # The canonical record for a host in a namespace, whatever its state, so
  # re-adoption and reservation reuse it instead of inserting another.
  defp lock_managed_host(organization_id, vrf_id, address) do
    IpAddress
    |> where([ip], ip.organization_id == ^organization_id)
    |> where_vrf(vrf_id)
    |> where(
      [ip],
      fragment("host(?)::inet = host(?)::inet", ip.address, type(^address, Renga.Types.Inet))
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> Repo.preload(:resource)
  end

  defp lock_ip_address!(organization_id, id) do
    IpAddress
    |> where([ip], ip.organization_id == ^organization_id and ip.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
    |> Repo.preload([:resource, :vrf, assignments: [interface: :resource]])
  end

  defp insert_ip_address(scope, intent, attrs) do
    %Scope{organization_id: organization_id} = scope
    label = ip_address_label(intent.address, scoped_vrf(organization_id, intent.vrf_id))

    resource =
      case ResourceStore.insert(organization_id, %{
             kind: "ip_address",
             name: "ip-address-" <> Ecto.UUID.generate(),
             display_name: label,
             lifecycle_state: "active"
           }) do
        {:ok, resource} -> resource
        {:error, changeset} -> Repo.rollback(changeset)
      end

    ip_address =
      %IpAddress{organization_id: organization_id, resource_id: resource.id}
      |> struct(intent)
      |> IpAddress.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, ip_address} -> ip_address
        {:error, changeset} -> Repo.rollback(changeset)
      end

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "created",
        field: "ip_address",
        resource_id: resource.id,
        new_value: %{"value" => label}
      })

    %{ip_address | resource: resource}
  end

  @ip_address_event_fields [
    :address,
    :allocation_state,
    :management_mode,
    :role,
    :dns_name,
    :description
  ]

  # A released address comes back as the same record: lifecycle first, then
  # each intent field that differs, each written to Activity.
  defp reactivate(scope, %IpAddress{} = retired, intent, attrs) do
    resource = set_lifecycle!(scope, retired.resource, "active")

    updated =
      retired
      |> Ecto.Changeset.change(intent)
      |> IpAddress.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end

    record_ip_address_changes(scope, resource.id, retired, updated)
    %{updated | resource: resource}
  end

  # One `updated` change event per changed intent field.
  defp record_ip_address_changes(scope, resource_id, before, after_update) do
    for field <- @ip_address_event_fields,
        Map.fetch!(before, field) != Map.fetch!(after_update, field) do
      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "updated",
          field: Atom.to_string(field),
          resource_id: resource_id,
          old_value: ip_address_event_value(field, before),
          new_value: ip_address_event_value(field, after_update)
        })
    end
  end

  # Built from the submitted changeset when there is one, so a form shows
  # the error on the field the operator typed.
  defp already_managed(%IpAddress{} = current),
    do: current |> Ecto.Changeset.change() |> already_managed()

  defp already_managed(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.add_error(:address, "is already managed in this routing table")
    |> Map.put(:action, :insert)
  end

  defp set_lifecycle!(scope, resource, state) do
    updated =
      case ResourceStore.update(resource, %{lifecycle_state: state}) do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: "lifecycle_state",
        resource_id: resource.id,
        old_value: %{"value" => resource.lifecycle_state},
        new_value: %{"value" => state}
      })

    updated
  end

  defp assign!(scope, %IpAddress{} = ip_address, interface) do
    %IpAddressAssignment{
      organization_id: scope.organization_id,
      ip_address_id: ip_address.id,
      interface_id: interface.id,
      assigned_by_id: scope.user.id
    }
    |> IpAddressAssignment.changeset()
    |> Repo.insert()
    |> case do
      {:ok, _assignment} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: "assignment",
        resource_id: ip_address.resource_id,
        new_value: assignment_event_value(interface)
      })
  end

  defp unassign!(scope, %IpAddress{} = ip_address, %IpAddressAssignment{} = assignment) do
    Repo.delete!(assignment)

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: "assignment",
        resource_id: ip_address.resource_id,
        old_value: assignment_event_value(assignment.interface)
      })
  end

  # Names the interface for reading and keeps its id, since interface names
  # repeat across resources.
  defp assignment_event_value(interface) do
    %{
      "value" => "#{interface.name} on #{interface.resource.name}",
      "interface_id" => interface.id
    }
  end

  defp ip_address_event_value(:address, %IpAddress{address: address}),
    do: %{"value" => Cidr.format(address)}

  defp ip_address_event_value(field, %IpAddress{} = ip_address),
    do: %{"value" => Map.fetch!(ip_address, field)}

  # The envelope's display name is the host, and the VRF when there is one.
  defp ip_address_label(address, vrf) do
    host = Cidr.format(%{address | netmask: Cidr.bits(Cidr.family(address))})
    if vrf, do: "#{host} (#{vrf.name})", else: host
  end

  defp management_mode(%Address{} = observed) do
    case AddressAssignment.method(observed) do
      :unknown -> nil
      method -> Atom.to_string(method)
    end
  end

  @doc """
  Dual-stack coverage for a VLAN: which devices have addresses in its IPv4
  prefixes, its IPv6 prefixes, or both.

  `nil` when the VLAN does not carry both families in the global table,
  because coverage only means something once both are planned where
  addresses are observed; VRF prefixes have none yet (see the moduledoc).
  """
  def vlan_dual_stack(%Scope{organization_id: organization_id} = scope, vlan_id) do
    prefixes =
      scope
      |> Topology.list_vlan_prefixes(vlan_id)
      |> Enum.filter(&is_nil(&1.vrf_id))

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

  # Observed addresses are global until collectors report routing domains.
  defp addresses_in(_organization_id, %Prefix{vrf_id: vrf_id}) when not is_nil(vrf_id), do: []

  defp addresses_in(organization_id, %Prefix{prefix: cidr}) do
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
    # Use the winning presence observation's report of the current mask,
    # never another source's historical hints or another mask's report.
    |> join(:left, [address], evidence in AddressEvidence,
      on:
        evidence.organization_id == address.organization_id and evidence.address_id == address.id and
          evidence.address == address.address and
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

  # One query counts every prefix's occupied hosts at once: the union of
  # observed hosts (global until collectors report routing domains) and
  # current managed addresses in the prefix's own routing table. A host that
  # is both, or that several interfaces report, is used once. A small IPv4
  # prefix's network and broadcast addresses are not assignable, so they
  # never count.
  defp address_counts(_organization_id, []), do: %{}

  defp address_counts(organization_id, prefix_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT prefixes.id,
               count(DISTINCT occupied.host) FILTER (
                 WHERE NOT (family(prefixes.prefix) = 4
                            AND masklen(prefixes.prefix) BETWEEN 22 AND 30
                            AND (occupied.host = host(network(prefixes.prefix))::inet
                                 OR occupied.host = host(broadcast(prefixes.prefix))::inet))
               )
        FROM prefixes
        JOIN LATERAL (
          SELECT host(addresses.address)::inet AS host
          FROM addresses
          WHERE prefixes.vrf_id IS NULL
            AND addresses.organization_id = prefixes.organization_id
            AND (addresses.metadata->'present') IS DISTINCT FROM 'false'::jsonb
            AND host(addresses.address)::inet <<= prefixes.prefix
          UNION ALL
          SELECT host(ip_addresses.address)::inet
          FROM ip_addresses
          JOIN resources
            ON resources.id = ip_addresses.resource_id
           AND resources.organization_id = ip_addresses.organization_id
           AND resources.lifecycle_state = 'active'
          WHERE ip_addresses.organization_id = prefixes.organization_id
            AND ip_addresses.vrf_id IS NOT DISTINCT FROM prefixes.vrf_id
            AND host(ip_addresses.address)::inet <<= prefixes.prefix
        ) AS occupied ON true
        WHERE prefixes.organization_id = $1 AND prefixes.id = ANY($2)
        GROUP BY prefixes.id
        """,
        [Ecto.UUID.dump!(organization_id), Enum.map(prefix_ids, &Ecto.UUID.dump!/1)]
      )

    Map.new(rows, fn [id, count] -> {Ecto.UUID.load!(id), count} end)
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
