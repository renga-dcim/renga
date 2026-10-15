defmodule RengaWeb.Browser.CablesTest do
  @moduledoc """
  Cable endpoints at phone width: long interface and resource identities stay
  available through the overflow tooltip, and the endpoint remains a link to
  its resource.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Topology

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {first_resource, first} =
      interface_fixture(
        scope,
        "core-distribution-switch-building-a-floor-twenty-two",
        "forty-gigabit-ethernet-0/0/48"
      )

    {_second_resource, second} =
      interface_fixture(scope, "aggregation-switch-building-b", "forty-gigabit-ethernet-0/0/47")

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "fiber"
      })

    [cable] = Topology.list_cables(scope)

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

    %{conn: conn, cable: cable, first_resource: first_resource}
  end

  test "a clipped endpoint reveals its full identity and keeps resource navigation", context do
    endpoint =
      "#cable-#{context.cable.id} a[href='/inventory/#{context.first_resource.id}'] [data-clip]"

    context.conn
    |> visit("/network/cables")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.querySelector(#{Jason.encode!(endpoint)}).scrollWidth > document.querySelector(#{Jason.encode!(endpoint)}).clientWidth",
      &assert(&1 == true)
    )
    |> hover(endpoint)
    |> evaluate(
      @tooltip,
      &assert(
        &1 =~
          "forty-gigabit-ethernet-0/0/48 · core-distribution-switch-building-a-floor-twenty-two"
      )
    )
    |> click(endpoint)
    |> assert_path("/inventory/#{context.first_resource.id}")
  end

  defp hover(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} = PlaywrightEx.Frame.hover(frame_id, selector: selector, timeout: 2000)
    end)
  end

  defp interface_fixture(scope, resource_name, interface_name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "switch",
        name: resource_name,
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: interface_name})
    {resource, interface}
  end
end
