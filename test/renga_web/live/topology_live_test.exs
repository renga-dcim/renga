defmodule RengaWeb.TopologyLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Topology

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, scope: scope}
  end

  test "keeps logical relationships, reconciled adjacency, and unresolved evidence separate", %{
    conn: conn,
    scope: scope
  } do
    context = topology_context(scope)

    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(view, "#logical-relationships")
    assert has_element?(view, "#reconciled-adjacency")
    assert has_element?(view, "#neighbor-evidence")

    assert has_element?(
             view,
             "#relationship-#{context.relationship.id}[data-relationship-kind='bridge_member']"
           )

    assert has_element?(view, "#relationship-#{context.relationship.id}", context.local.name)
    assert has_element?(view, "#relationship-#{context.relationship.id}", context.bridge.name)

    assert has_element?(
             view,
             "#adjacency-#{context.adjacency.id}[data-adjacency-confidence='reported']"
           )

    assert has_element?(view, "#adjacency-#{context.adjacency.id}", context.remote.name)

    assert has_element?(
             view,
             "#neighbor-evidence-#{context.unresolved.id}[data-evidence-protocol='lldp']"
           )

    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}", "ghost-switch:swp9")

    # Adjacency and evidence are distinct sections, not one merged connection list.
    refute has_element?(view, "#logical-relationships #adjacency-#{context.adjacency.id}")
    refute has_element?(view, "#reconciled-adjacency #neighbor-evidence-#{context.unresolved.id}")
  end

  test "filters every section by one interface", %{conn: conn, scope: scope} do
    context = topology_context(scope)
    other = topology_context(scope, tag: "other")

    # Reconciling another resource rebuilds current adjacency rows, so re-read
    # the first context's adjacency before asserting its DOM id.
    [adjacency] =
      Topology.list_organization_interface_adjacencies(scope, interface_id: context.local.id)

    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[interface_id: context.local.id]}")

    assert has_element?(view, "#topology-clear-interface")
    assert has_element?(view, "#relationship-#{context.relationship.id}")
    assert has_element?(view, "#adjacency-#{adjacency.id}")
    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}")

    refute has_element?(view, "#relationship-#{other.relationship.id}")
    refute has_element?(view, "#adjacency-#{other.adjacency.id}")
    refute has_element?(view, "#neighbor-evidence-#{other.unresolved.id}")
  end

  test "keeps another organization's topology invisible", %{conn: conn, scope: scope} do
    context = topology_context(scope)

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign = topology_context(foreign_scope, tag: "foreign")

    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(view, "#relationship-#{context.relationship.id}")
    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}")
    refute has_element?(view, "#relationship-#{foreign.relationship.id}")
    refute has_element?(view, "#neighbor-evidence-#{foreign.unresolved.id}")
  end

  test "members read the organization topology", %{
    organization: organization,
    scope: scope
  } do
    context = topology_context(scope)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/network/topology")

    assert has_element?(view, "#adjacency-#{context.adjacency.id}")
    assert has_element?(view, "#network-topology")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/topology")
    assert path =~ "/users/log-in"
  end

  defp topology_context(scope, opts \\ []) do
    tag = Keyword.get(opts, :tag, "topology-ui")
    suffix = System.unique_integer([:positive])

    {:ok, local_resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "#{tag}-local-#{suffix}",
        lifecycle_state: "active"
      })

    {:ok, remote_resource} =
      Inventory.create_resource(scope, %{
        kind: "switch",
        name: "#{tag}-remote-#{suffix}",
        lifecycle_state: "active"
      })

    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, bridge} =
      Inventory.create_interface(scope, local_resource.id, %{name: "br0", kind: "bridge"})

    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    {:ok, relationship} =
      Inventory.create_interface_relationship(scope, local.id, bridge.id, %{kind: "bridge_member"})

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "#{tag}-source-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "#{tag}-observation-#{suffix}",
        observed_at: ~U[2099-09-08 14:00:00Z],
        payload: %{}
      })

    assert {:ok, evidence} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               observation,
               local_resource.id,
               [
                 %{
                   "name" => "eth0",
                   "neighbors" => [
                     %{
                       "protocol" => "lldp",
                       "remote_chassis_id" => remote_resource.name,
                       "remote_port_id" => remote.name,
                       "ttl_seconds" => 120,
                       "metadata" => %{}
                     },
                     %{
                       "protocol" => "lldp",
                       "remote_chassis_id" => "ghost-switch",
                       "remote_port_id" => "swp9",
                       "ttl_seconds" => 120,
                       "metadata" => %{}
                     }
                   ]
                 }
               ],
               true
             )

    assert [%{status: "matched"}] =
             evidence
             |> Enum.map(&Topology.get_interface_neighbor_match(scope, &1.id))
             |> Enum.filter(&(&1.status == "matched"))

    [unresolved] = Enum.reject(evidence, &matched?(scope, &1))
    [adjacency] = Topology.list_organization_interface_adjacencies(scope, interface_id: local.id)

    %{
      local: local,
      remote: remote,
      bridge: bridge,
      relationship: relationship,
      adjacency: adjacency,
      unresolved: unresolved
    }
  end

  defp matched?(scope, evidence) do
    Topology.get_interface_neighbor_match(scope, evidence.id).status == "matched"
  end
end
