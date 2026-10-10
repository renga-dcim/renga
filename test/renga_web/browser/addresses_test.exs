defmodule RengaWeb.Browser.AddressesTest do
  @moduledoc """
  The address list in a real browser: an admin reserves an address and
  assigns it by searching for an interface, and at phone width the list
  stays readable without horizontal scrolling and without controls, because
  addresses are not edited on a phone.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {_host, ports} = device_fixture(scope, "server", "web-01", ~w(eth0))
    observed = address_fixture(scope, ports["eth0"], "2001:db8:abcd:12::5/64")
    {:ok, adopted} = Renga.IPAM.adopt_address(scope, observed.id)

    {:ok, _} =
      Renga.IPAM.update_ip_address(scope, adopted, %{
        dns_name: "a-very-long-service-name.internal.datacenter-one.example.net"
      })

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, scope: scope, adopted: adopted, eth0: ports["eth0"]}
  end

  test "an admin reserves an address and assigns it by interface search", context do
    session =
      context.conn
      |> visit("/network/addresses?q=192.0.2.0%2F24&vrf=global")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#new-address")
      |> assert_has("#address-panel [role=dialog]", text: "Reserve address")
      |> fill_in("#address-form input[name='ip_address[address]']", "Address",
        with: "192.0.2.10/24"
      )
      |> PhoenixTest.Playwright.click("#save-address")
      |> assert_has("#flash-info", text: "192.0.2.10 reserved")
      |> refute_has("#address-panel [role=dialog]")

    reserved = Renga.Repo.get_by!(Renga.IPAM.IpAddress, allocation_state: "reserved")

    session
    |> PhoenixTest.Playwright.click("#address-#{reserved.id}-edit")
    |> assert_has("#address-panel [role=dialog]", text: "Edit 192.0.2.10")
    |> refute_has("#flash-info")
    |> fill_in("#address-form input[name='ip_address[description]']", "Description (optional)",
      with: "Unsaved intent"
    )
    |> fill_in("#assign-interface", "Assign to an interface", with: "web")
    |> press("#assign-interface", "Enter")
    |> assert_has("#assign-#{context.eth0.id}")
    |> assert_has("#address-panel [role=dialog]", text: "Edit 192.0.2.10")
    |> evaluate(
      "document.querySelector('#address-form input[name=\"ip_address[description]\"]').value",
      &assert(&1 == "Unsaved intent")
    )
    |> evaluate("window.location.search", fn query ->
      assert URI.decode_query(String.trim_leading(query, "?")) == %{
               "q" => "192.0.2.0/24",
               "vrf" => "global"
             }
    end)
    |> PhoenixTest.Playwright.click("#assign-#{context.eth0.id}")
    |> assert_has("#address-assignments", text: "eth0")
    |> assert_has("#address-#{reserved.id}", text: "web-01")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "addresses are readable but not editable on a phone", context do
    context.conn
    |> visit("/network/addresses")
    |> assert_has("body .phx-connected")
    |> assert_has("#address-#{context.adopted.id}", text: "2001:db8:abcd:12::5/64")
    |> evaluate(visible_js("new-address"), &assert(&1 == false))
    |> evaluate(visible_js("address-#{context.adopted.id}-edit"), &assert(&1 == false))
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(
      "(el => el.scrollWidth <= el.clientWidth)(document.getElementById('address-list').closest('div'))",
      &assert(&1 == true)
    )
  end

  defp visible_js(id), do: "document.getElementById('#{id}').checkVisibility()"
end
