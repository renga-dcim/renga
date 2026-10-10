defmodule RengaWeb.RoutingDomainLiveTest do
  @moduledoc """
  Routing domains in the UI (RFD 4, Phase 6): the VRFs page lists what
  collectors report and how it resolved, where owners and admins map keys
  and set source authority; a resource's interfaces show their domain; and
  an unmapped domain's finding links to its mapping.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.IPAM.AddressFinding
  alias Renga.IPAM.RoutingDomains
  alias Renga.Repo
  alias RengaWeb.VrfLive

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    {:ok, agent} = Inventory.create_source(admin, %{kind: "host_agent", name: "agent"})
    blue = vrf_fixture(admin, "blue")

    resource =
      report(admin, agent, [
        {"eth0", %{"key" => "lab"}},
        {"eth1", %{"key" => "blue"}},
        {"eth2", :absent}
      ])

    %{
      admin_conn: admin_conn,
      admin: admin,
      member_conn: member_conn,
      agent: agent,
      blue: blue,
      resource: Repo.preload(resource, :interfaces)
    }
  end

  test "an admin maps a reported domain and sets source authority", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/vrfs")
    lab = "#routing-domain-#{VrfLive.domain_id(context.agent.id, "lab")}"
    blue = "#routing-domain-#{VrfLive.domain_id(context.agent.id, "blue")}"

    assert has_element?(view, "#{lab} [data-resolution=unmapped]", "1 interface")
    assert has_element?(view, "#{blue} [data-resolution=name]", "VRF blue")

    view
    |> form("#{lab}-form")
    |> render_change(%{mapping: %{target: context.blue.id}})

    assert has_element?(view, "#flash-info", "lab mapped")
    assert has_element?(view, "#{lab} [data-resolution=mapping]", "VRF blue")
    refute has_element?(view, "[data-resolution=unmapped]")

    # Back to automatic, the key is unmapped again; the global table is an
    # explicit choice too.
    view |> form("#{lab}-form") |> render_change(%{mapping: %{target: "automatic"}})
    assert has_element?(view, "#{lab} [data-resolution=unmapped]")
    view |> form("#{lab}-form") |> render_change(%{mapping: %{target: "global"}})
    assert has_element?(view, "#{lab} [data-resolution=mapping]", "Global table")

    assert has_element?(
             view,
             "#source-#{context.agent.id}-authority-form input[type=checkbox][checked]"
           )

    view
    |> form("#source-#{context.agent.id}-authority-form")
    |> render_change(%{authority: %{authoritative: "false"}})

    assert has_element?(view, "#flash-info", "agent's routing domains are advisory")
    refute Repo.reload!(context.agent).authoritative_routing_domains
  end

  test "a mapping of a key nobody reports now stays listed", context do
    {:ok, _} = RoutingDomains.put_mapping(context.admin, context.agent.id, "old", nil)
    {:ok, view, _html} = live(context.member_conn, ~p"/network/vrfs")

    assert has_element?(
             view,
             "#routing-domain-#{VrfLive.domain_id(context.agent.id, "old")}",
             "Not reported now"
           )
  end

  test "members see routing domains but cannot change them", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/network/vrfs")

    assert has_element?(view, "#routing-domain-list", "lab")
    refute has_element?(view, "#routing-domain-list form")
    refute has_element?(view, "#routing-domain-authority form")
    assert has_element?(view, "#source-#{context.agent.id}-authority", "Authoritative")

    render_hook(view, "map_domain", %{
      "mapping" => %{"source_id" => context.agent.id, "key" => "lab", "target" => "global"}
    })

    assert has_element?(view, "#flash-error", "Only owners and admins manage routing domains")

    render_hook(view, "set_authority", %{
      "authority" => %{"source_id" => context.agent.id, "authoritative" => "false"}
    })

    assert Repo.reload!(context.agent).authoritative_routing_domains
    assert RoutingDomains.list_mappings(context.admin) == []
  end

  test "a resource's interfaces show their routing domain and unmapped finding", context do
    ports = Map.new(context.resource.interfaces, &{&1.name, &1})
    {:ok, view, _html} = live(context.member_conn, ~p"/inventory/#{context.resource}/network")

    assert has_element?(
             view,
             "#interface-#{ports["eth0"].id}-routing-domain[data-resolution=unmapped]",
             "lab"
           )

    assert has_element?(view, "#interface-#{ports["eth1"].id}-routing-domain", "VRF blue")
    refute has_element?(view, "#interface-#{ports["eth2"].id}-routing-domain")

    assert has_element?(
             view,
             "#interface-#{ports["eth0"].id}-address-findings",
             "Routing domain lab reported by agent is not mapped to a VRF"
           )
  end

  test "the Inbox links an unmapped domain's finding to its mapping", context do
    [finding] = Repo.all(AddressFinding)
    assert finding.kind == "unmapped_routing_domain"

    {:ok, view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[finding: "address:#{finding.id}"]}")

    assert has_element?(view, "#finding-panel", "Unmapped routing domain")
    assert has_element?(view, "#finding-properties", "IP addresses")

    assert has_element?(
             view,
             "#address-finding-routing-domains[href='/network/vrfs#routing-domains']",
             "Map routing domain lab"
           )

    refute has_element?(view, "#address-finding-addresses")
    refute has_element?(view, "#address-finding-adopt")
  end

  # Reports one server's interfaces with routing-domain claims; `:absent`
  # leaves the field out.
  defp report(scope, source, claims) do
    interfaces =
      Enum.map(claims, fn
        {name, :absent} -> %{"name" => name}
        {name, claim} -> %{"name" => name, "routing_domain" => claim}
      end)

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "routing-domains",
        observed_at: ~U[2026-08-01 12:00:00Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "router-1"},
              "interfaces" => interfaces
            }
          ]
        }
      })

    {:ok, resource, _created?} = Inventory.reconcile_observation(scope, observation.id)
    resource
  end

  defp sign_in(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
