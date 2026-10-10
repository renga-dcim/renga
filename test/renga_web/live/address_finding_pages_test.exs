defmodule RengaWeb.AddressFindingPagesTest do
  @moduledoc """
  Address findings on the pages of the records they affect (RFD 4,
  "User interaction"): the prefix, the managed address, and the resource's
  interfaces each list theirs and link to the Inbox.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.Repo

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {web, web_ports} = device_fixture(scope, "server", "web-01", ~w(eth0 eth1))
    {_db, db_ports} = device_fixture(scope, "server", "db-01", ~w(eth0))
    prefix = prefix_fixture(scope, "192.0.2.0/24")
    observed = address_fixture(scope, web_ports["eth0"], "192.0.2.9/24")
    address_fixture(scope, db_ports["eth0"], "192.0.2.9/24")
    {:ok, managed} = IPAM.adopt_address(scope, observed.id)

    %{
      conn: conn,
      scope: scope,
      web: web,
      web_eth0: web_ports["eth0"],
      web_eth1: web_ports["eth1"],
      prefix: prefix,
      managed: managed,
      duplicates: Repo.all(AddressFinding)
    }
  end

  test "a prefix lists the findings about addresses inside it", context do
    [web_finding, db_finding] =
      Enum.sort_by(context.duplicates, &(&1.interface_id != context.web_eth0.id))

    {:ok, view, _html} = live(context.conn, ~p"/network/prefixes/#{context.prefix}")

    assert has_element?(view, "#prefix-findings", "2 address findings")

    assert has_element?(
             view,
             "#prefix-finding-list-#{web_finding.id} a[href='/inbox?finding=address%3A#{web_finding.id}']",
             "Duplicate address"
           )

    assert has_element?(view, "#prefix-finding-list-#{db_finding.id}", "db-01")

    # Another prefix, or one in a VRF, has none of them.
    other = prefix_fixture(context.scope, "198.51.100.0/24")
    {:ok, view, _html} = live(context.conn, ~p"/network/prefixes/#{other}")
    refute has_element?(view, "#prefix-findings")

    in_vrf = prefix_fixture(context.scope, "192.0.2.0/24", %{vrf: "blue"})
    {:ok, view, _html} = live(context.conn, ~p"/network/prefixes/#{in_vrf}")
    refute has_element?(view, "#prefix-findings")
  end

  test "a managed address shows its findings in the list and its panel", context do
    {:ok, in_vrf} =
      IPAM.create_ip_address(context.scope, %{
        address: "192.0.2.9/24",
        vrf_id: vrf_fixture(context.scope, "blue").id
      })

    {:ok, view, _html} = live(context.conn, ~p"/network/addresses")

    assert has_element?(
             view,
             "#address-#{context.managed.id}-findings[href='/inbox?domain=address']",
             "2 findings"
           )

    # The same host in a VRF is another address, not observed yet.
    refute has_element?(view, "#address-#{in_vrf.id}-findings")

    view |> element("#address-#{context.managed.id}-edit") |> render_click()
    assert has_element?(view, "#address-findings #address-finding-list", "web-01")
    assert has_element?(view, "#address-findings #address-finding-list", "db-01")
  end

  test "a resource shows each interface's address findings on its Network tab", context do
    {:ok, view, _html} = live(context.conn, ~p"/inventory/#{context.web}/network")

    assert has_element?(
             view,
             "#interface-#{context.web_eth0.id}-address-findings",
             "192.0.2.9 is also observed on eth0 on db-01"
           )

    refute has_element?(view, "#interface-#{context.web_eth1.id}-address-findings")

    # A VIP may be on both; the findings resolve and leave the page.
    {:ok, _vip} = IPAM.update_ip_address(context.scope, context.managed, %{role: "vip"})
    {:ok, view, _html} = live(context.conn, ~p"/inventory/#{context.web}/network")
    refute has_element?(view, "#interface-#{context.web_eth0.id}-address-findings")
  end
end
