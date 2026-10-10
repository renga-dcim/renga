defmodule RengaWeb.AddressingPlanLiveTest do
  @moduledoc """
  The addressing plan on the Prefixes page (RFD 4, Phase 7): everyone sees
  the plan and the planned level in each container's usage; owners and
  admins add and remove levels from a side panel.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    site = prefix_fixture(admin, "2001:db8:a::/48", %{status: "container"})
    prefix_fixture(admin, "2001:db8:a:1::/64")
    %{admin_conn: admin_conn, admin: admin, member_conn: member_conn, site: site}
  end

  test "an admin adds and removes plan levels and containers follow them", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes")
    usage = "#prefix-row-#{context.site.id}-usage"

    refute has_element?(view, "#addressing-plan")
    assert has_element?(view, usage, "of 65,536 /64s")

    view
    |> form("#plan-level-form", plan_level: %{family: "ipv6", prefix_length: "56", name: "hall"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "/56 hall added to the plan")
    assert has_element?(view, "#addressing-plan-ipv6", "/56 hall")
    assert has_element?(view, usage, "of 256 hall /56s")

    # The same length twice is refused in the form.
    view
    |> form("#plan-level-form", plan_level: %{family: "ipv6", prefix_length: "56", name: "room"})
    |> render_submit()

    assert has_element?(view, "#plan-level-form", "is already a level of this family's plan")

    [level] = IPAM.list_plan_levels(context.admin)
    view |> element("#plan-level-#{level.id}-delete") |> render_click()

    assert has_element?(view, "#flash-info", "/56 hall removed from the plan")
    refute has_element?(view, "#addressing-plan")
    assert has_element?(view, usage, "of 65,536 /64s")
  end

  test "members see the plan but cannot change it", context do
    {:ok, level} =
      IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 56, name: "hall"})

    {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes")

    assert has_element?(view, "#addressing-plan-ipv6", "/56 hall")
    refute has_element?(view, "#edit-plan")
    refute has_element?(view, "#plan-level-form")

    render_hook(view, "create_plan_level", %{
      "plan_level" => %{"family" => "ipv4", "prefix_length" => "24", "name" => "rack"}
    })

    assert has_element?(view, "#flash-error", "Only owners and admins manage the addressing plan")
    render_hook(view, "delete_plan_level", %{"id" => level.id})
    assert [_] = IPAM.list_plan_levels(context.admin)
  end

  test "a plan changed elsewhere reaches an open page", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes")

    {:ok, _} =
      IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 56, name: "hall"})

    send(view.pid, :reload)
    assert has_element?(view, "#addressing-plan-ipv6", "/56 hall")
  end

  test "a prefix's child space names its planned level", context do
    {:ok, _} =
      IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 56, name: "hall"})

    {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes/#{context.site}")
    assert has_element?(view, "#prefix-space-summary", "of 256 hall /56s allocated")
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
