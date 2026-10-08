defmodule Renga.TriageFixtures do
  @moduledoc """
  Test helpers for triage and triage rules: servers with hostnames and
  addresses, collector reports reconciled as ingestion does, and LLDP
  neighbors.
  """

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Topology

  def resource_fixture(scope, kind, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: kind, name: name, lifecycle_state: "active"})

    resource
  end

  @doc "A server, optionally with a `:hostname` and an IPv4 `:address` on eth0."
  def server_fixture(scope, name, opts \\ []) do
    resource = resource_fixture(scope, "server", name)

    if hostname = opts[:hostname] do
      {:ok, _host} = Inventory.create_host(scope, resource.id, %{hostname: hostname})
    end

    if address = opts[:address] do
      {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

      {:ok, _address} =
        Inventory.create_address(scope, interface.id, %{kind: "ipv4", address: address})
    end

    resource
  end

  @doc """
  A host agent report of a new server, reconciled as the system the way
  ingestion does, so triage rules apply. Options: `:reported_from` (an
  address tuple), `:intake_api_key_id`, `:labels`.
  """
  def report_fixture(scope, machine_id, opts \\ []) do
    source =
      case Inventory.list_sources(scope) do
        [source | _rest] ->
          source

        [] ->
          {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent"})
          source
      end

    reported_from =
      opts[:reported_from] && %Postgrex.INET{address: opts[:reported_from], netmask: nil}

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: machine_id,
        observed_at: DateTime.utc_now(),
        reported_from: reported_from,
        intake_api_key_id: opts[:intake_api_key_id],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => machine_id},
              "attributes" => %{"hostname" => machine_id},
              "labels" => opts[:labels] || %{}
            }
          ]
        }
      })

    system = %Scope{organization_id: scope.organization_id}
    {:ok, resource, true} = Inventory.reconcile_observation_once(system, observation.id)
    resource
  end

  @doc "A current, matched LLDP neighbor from `local`'s interface to `switch`."
  def lldp_fixture(scope, local, switch, interface_name \\ "eth0") do
    {:ok, local_interface} = Inventory.create_interface(scope, local.id, %{name: interface_name})

    {:ok, remote_interface} =
      Inventory.create_interface(scope, switch.id, %{name: "swp-#{local.name}-#{interface_name}"})

    tag = "lldp-#{local.name}-#{switch.name}-#{interface_name}"
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: tag})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: tag,
        observed_at: DateTime.utc_now(),
        payload: %{}
      })

    {:ok, [_evidence]} =
      Topology.reconcile_interface_neighbors(
        scope,
        source,
        observation,
        local.id,
        [
          %{
            "name" => local_interface.name,
            "neighbors" => [
              %{
                "protocol" => "lldp",
                "remote_chassis_id" => switch.name,
                "remote_port_id" => remote_interface.name,
                "ttl_seconds" => 120,
                "metadata" => %{}
              }
            ]
          }
        ],
        true
      )

    :ok
  end
end
