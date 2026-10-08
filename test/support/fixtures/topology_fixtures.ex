defmodule Renga.TopologyFixtures do
  @moduledoc """
  Test helpers for the three cabling layers: plans, neighbor evidence, and
  confirmed cables.
  """

  alias Renga.Inventory
  alias Renga.Topology

  @doc "Creates a resource of `kind` with one interface per name."
  def device_fixture(scope, kind, name, interface_names) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: kind, name: name, lifecycle_state: "active"})

    interfaces =
      Map.new(interface_names, fn interface_name ->
        {:ok, interface} =
          Inventory.create_interface(scope, resource.id, %{name: interface_name})

        {interface_name, interface}
      end)

    {resource, interfaces}
  end

  @doc """
  Reports one resource's LLDP neighbors as a current snapshot.

  `neighbors` maps a local interface name to `{remote_resource, remote_port}`
  pairs, matched by chassis name. A snapshot replaces the resource's earlier
  reports, so pass every neighbor the resource currently sees.
  """
  def report_neighbors(scope, resource, neighbors) do
    suffix = System.unique_integer([:positive])

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "lldp-#{resource.name}-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "lldp-#{resource.name}-#{suffix}",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{}
      })

    interfaces =
      Enum.map(neighbors, fn {name, remotes} ->
        %{
          "name" => name,
          "neighbors" =>
            Enum.map(List.wrap(remotes), fn {remote_chassis, remote_port} ->
              %{
                "protocol" => "lldp",
                "remote_chassis_id" => remote_chassis,
                "remote_port_id" => remote_port,
                "ttl_seconds" => 600,
                "metadata" => %{}
              }
            end)
        }
      end)

    {:ok, evidence} =
      Topology.reconcile_interface_neighbors(
        scope,
        source,
        observation,
        resource.id,
        interfaces,
        true
      )

    evidence
  end

  @doc "Records an operator-confirmed cable between two interfaces."
  def cable_fixture(scope, first, second, attrs \\ %{}) do
    {:ok, assertion} =
      Topology.assert_cable(
        scope,
        Map.merge(%{interface_a_id: first.id, interface_b_id: second.id}, attrs)
      )

    assertion
  end

  @doc "Plans a cable between two interfaces."
  def cable_plan_fixture(scope, first, second, attrs \\ %{}) do
    {:ok, plan} =
      Topology.put_cable_plan(
        scope,
        Map.merge(%{interface_a_id: first.id, interface_b_id: second.id}, attrs)
      )

    plan
  end

  @doc "Creates an active global VLAN group covering `ranges` of VIDs."
  def vlan_group_fixture(scope, slug, ranges \\ [{1, 4094}]) do
    {:ok, group} =
      Topology.create_vlan_group(
        scope,
        %{name: String.capitalize(slug), lifecycle_state: "active"},
        %{slug: slug, scope_kind: "global", status: "active"},
        Enum.map(ranges, fn {start_vid, end_vid} -> %{start_vid: start_vid, end_vid: end_vid} end)
      )

    group
  end

  @doc "Creates an active VLAN in `group`."
  def vlan_fixture(scope, group, vid, name) do
    {:ok, vlan} =
      Topology.create_vlan(
        scope,
        %{name: "#{group.id}/#{vid}"},
        %{vlan_group_id: group.id, vid: vid, name: name, status: "active"}
      )

    vlan
  end

  @doc """
  Sets an interface's desired VLAN mode and membership.

  `untagged` is a VLAN or `nil`; `tagged` is a list of VLANs.
  """
  def desire_vlans(scope, interface, mode, untagged, tagged \\ []) do
    {:ok, _mode} = Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: mode})

    for {vlan, tagging} <-
          Enum.map(List.wrap(untagged), &{&1, "untagged"}) ++
            Enum.map(tagged, &{&1, "tagged"}) do
      {:ok, _assignment} =
        Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
          tagging_mode: tagging
        })
    end

    :ok
  end

  @doc """
  Reports one resource's observed VLANs as a current snapshot from a source
  mapped to `group`.

  `interfaces` maps an interface name to `{mode, [{vid, tagging_mode}]}`.
  """
  def report_vlans(scope, resource, group, interfaces) do
    suffix = System.unique_integer([:positive])

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "vlans-#{resource.name}-#{suffix}"})

    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "vlans-#{resource.name}-#{suffix}",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{}
      })

    reported =
      Enum.map(interfaces, fn {name, {mode, vlans}} ->
        %{
          "name" => name,
          "vlan_mode" => mode,
          "vlans" =>
            Enum.map(vlans, fn {vid, tagging} -> %{"vid" => vid, "tagging_mode" => tagging} end)
        }
      end)

    {:ok, evidence} =
      Topology.reconcile_interface_vlans(scope, source, observation, resource.id, reported, true)

    evidence
  end
end
