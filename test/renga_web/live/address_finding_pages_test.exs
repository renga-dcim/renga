defmodule RengaWeb.AddressFindingPagesTest do
  @moduledoc """
  Address findings on the pages of the records they affect (RFD 4,
  "User interaction"): the prefix, the managed address, and the resource's
  interfaces each list theirs and link to the Inbox.
  """
  # The real expiry timer test holds its fixture transaction for 30 seconds.
  use RengaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.Findings
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

    assert eventually(fn ->
             not has_element?(view, "#interface-#{context.web_eth0.id}-address-findings")
           end)

    refute has_element?(view, "#interface-#{context.web_eth0.id}-address-findings")
  end

  test "the open editor retains findings when unassignment removes its filtered row", context do
    {:ok, view, _} = live(context.conn, ~p"/network/addresses?q=web-01")
    view |> element("#address-#{context.managed.id}-edit") |> render_click()
    [assignment] = context.managed.assignments
    view |> element("#assignment-#{assignment.id}-remove") |> render_click()
    refute has_element?(view, "#address-#{context.managed.id}")
    assert has_element?(view, "#address-findings", "web-01")
    assert has_element?(view, "#address-findings", "db-01")
  end

  test "overflow preserves old host counts and discloses bounded details on every surface",
       context do
    {:ok, crowded} = IPAM.create_ip_address(context.scope, %{address: "192.0.2.10/24"})
    now = Renga.Time.utc_now_ms()

    interfaces =
      for n <- 1..501 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: context.scope.organization_id,
          resource_id: context.web.id,
          name: "port#{n}",
          kind: "ethernet",
          status: "up",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Renga.Inventory.Interface, interfaces)

    rows =
      for interface <- interfaces do
        %{
          id: Ecto.UUID.generate(),
          organization_id: context.scope.organization_id,
          interface_id: interface.id,
          kind: "duplicate_address",
          resolution_key: "192.0.2.10",
          status: "open",
          message: "192.0.2.10 is duplicated",
          details: %{"address" => "192.0.2.10/24"},
          last_observed_at: DateTime.add(now, 1),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(AddressFinding, rows)
    {:ok, view, _} = live(context.conn, ~p"/network/addresses")

    assert has_element?(
             view,
             "#address-#{context.managed.id}-findings[href='/inbox?domain=address']",
             "2 findings"
           )

    assert has_element?(view, "#address-#{crowded.id}-findings", "501 findings")
    view |> element("#address-#{crowded.id}-edit") |> render_click()
    assert has_element?(view, "#address-finding-list-truncated", "Showing first 500 of 501")
    {:ok, prefix_view, _} = live(context.conn, ~p"/network/prefixes/#{context.prefix}")
    assert has_element?(prefix_view, "#prefix-findings h2", "503 address findings")
    assert has_element?(prefix_view, "#prefix-finding-list-truncated", "Showing first 500 of 503")
    {:ok, resource_view, _} = live(context.conn, ~p"/inventory/#{context.web}/network")

    assert has_element?(
             resource_view,
             "#resource-address-findings-truncated",
             "Showing first 500 of 502"
           )

    assert has_element?(
             resource_view,
             "#resource-address-findings-truncated a[href='/inbox?domain=address&resource=#{context.web.id}']"
           )
  end

  @tag timeout: 45_000
  test "idle pages refresh snooze and exception expiry without broadcasts or losing drafts",
       context do
    [first, second] = context.duplicates
    until = DateTime.add(Renga.Time.utc_now_ms(), 2)

    {:ok, _} =
      Findings.snooze(
        context.scope,
        Findings.get_finding!(context.scope, "address", first.id),
        until
      )

    {:ok, _} =
      Findings.accept_exception(
        context.scope,
        Findings.get_finding!(context.scope, "address", second.id),
        %{"exception_reason" => "Temporary", "exception_expires_at" => until}
      )

    {:ok, address_view, _} = live(context.conn, ~p"/network/addresses")
    {:ok, prefix_view, _} = live(context.conn, ~p"/network/prefixes/#{context.prefix}")
    address_view |> element("#address-#{context.managed.id}-edit") |> render_click()

    address_view
    |> form("#address-form", ip_address: %{description: "address draft"})
    |> render_change()

    prefix_view
    |> form("#prefix-edit-form", prefix: %{description: "prefix draft"})
    |> render_change()

    refute has_element?(address_view, "#address-#{context.managed.id}-findings")
    assert has_element?(prefix_view, "#prefix-finding-list", "Snoozed")
    assert has_element?(prefix_view, "#prefix-finding-list", "Exception")

    assert eventually(
             fn ->
               has_element?(address_view, "#address-#{context.managed.id}-findings", "2 findings")
             end,
             640
           )

    assert eventually(fn -> not has_element?(prefix_view, "#prefix-finding-list", "Snoozed") end)
    refute has_element?(prefix_view, "#prefix-finding-list", "Exception")

    assert has_element?(
             address_view,
             "#address-form input[name='ip_address[description]'][value='address draft']"
           )

    assert has_element?(
             prefix_view,
             "#prefix-edit-form input[name='prefix[description]'][value='prefix draft']"
           )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(50)
          eventually(fun, attempts - 1)
        )
  end
end
