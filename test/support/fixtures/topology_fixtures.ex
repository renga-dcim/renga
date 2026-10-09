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
end
