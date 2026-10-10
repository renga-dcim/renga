defmodule RengaWeb.NextFreeLiveTest do
  @moduledoc """
  "Next free" on a prefix's page (RFD 4, Phase 7): owners and admins
  preview and take the first free child prefix or host from a side panel,
  and the allocation re-reads the space rather than trusting the preview.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.Cidr

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    %{admin_conn: admin_conn, admin: admin, member_conn: member_conn}
  end

  test "a container hands out its next free child at its planning level", context do
    site = prefix_fixture(context.admin, "10.0.0.0/16", %{status: "container"})
    prefix_fixture(context.admin, "10.0.0.0/24")

    {:ok, _} =
      IPAM.create_plan_level(context.admin, %{family: "ipv4", prefix_length: 24, name: "rack"})

    {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{site}")

    assert has_element?(
             view,
             "#next-free-form select[name='next_free[kind]'] option[selected][value=prefix]"
           )

    assert has_element?(view, "#next-free-form input[name='next_free[length]'][value='24']")
    assert has_element?(view, "#next-free-preview", "Next free: 10.0.1.0/24")
    assert has_element?(view, "#allocate", "Allocate 10.0.1.0/24")

    view
    |> form("#next-free-form", next_free: %{status: "reserved", description: "Rack 2"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Allocated 10.0.1.0/24")
    assert has_element?(view, "#next-free-preview", "Next free: 10.0.2.0/24")

    assert [%{status: "reserved", description: "Rack 2"}] =
             context.admin
             |> IPAM.list_prefix_rows(nil)
             |> Map.fetch!(:ipv4)
             |> Enum.map(& &1.node.prefix)
             |> Enum.filter(&(Cidr.format(&1.prefix) == "10.0.1.0/24"))

    # Another length previews its own next block; an impossible one says why
    # and cannot be submitted.
    render_change(view, "preview_next_free", %{
      "next_free" => %{"kind" => "prefix", "length" => "20"}
    })

    assert has_element?(view, "#next-free-preview", "Next free: 10.0.16.0/20")

    render_change(view, "preview_next_free", %{
      "next_free" => %{"kind" => "prefix", "length" => "8"}
    })

    assert has_element?(view, "#next-free-preview", "Choose a length longer than this prefix's")
    assert has_element?(view, "#allocate[disabled]")

    # A container's space belongs to its children, so it offers no host.
    render_change(view, "preview_next_free", %{"next_free" => %{"kind" => "address"}})
    assert has_element?(view, "#next-free-preview", "Hosts are allocated in leaf prefixes")

    # Switching back keeps the length the prefix fields last had, though the
    # host fields' change did not send it.
    render_change(view, "preview_next_free", %{"next_free" => %{"kind" => "prefix"}})
    assert has_element?(view, "#next-free-form input[name='next_free[length]'][value='8']")
  end

  test "a leaf hands out its next free host as a managed address", context do
    lan = prefix_fixture(context.admin, "192.0.2.0/30")
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{lan}")

    assert has_element?(view, "#next-free-preview", "Next free: 192.0.2.1/30")

    view
    |> form("#next-free-form", next_free: %{kind: "address", dns_name: "gw.example.net"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Allocated 192.0.2.1/30")

    assert [%{dns_name: "gw.example.net", allocation_state: "allocated"}] =
             IPAM.list_ip_addresses(context.admin)

    {:ok, _} = IPAM.allocate_address(context.admin, lan)
    send(view.pid, :reload)

    assert has_element?(view, "#next-free-preview", "No free host is left.")
    assert has_element?(view, "#allocate[disabled]")
  end

  test "a stale preview allocates what is free when submitted", context do
    lan = prefix_fixture(context.admin, "192.0.2.0/24")
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/prefixes/#{lan}")
    assert has_element?(view, "#next-free-preview", "Next free: 192.0.2.1/24")

    # Someone else takes .1 before this page reloads.
    {:ok, _} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.1/24"})

    view |> form("#next-free-form") |> render_submit()
    assert has_element?(view, "#flash-info", "Allocated 192.0.2.2/24")
  end

  test "members see no allocation controls and cannot allocate", context do
    lan = prefix_fixture(context.admin, "192.0.2.0/24")
    {:ok, view, _html} = live(context.member_conn, ~p"/network/prefixes/#{lan}")

    refute has_element?(view, "#next-free")
    refute has_element?(view, "#next-free-form")

    render_hook(view, "allocate", %{"next_free" => %{"kind" => "address"}})
    assert has_element?(view, "#flash-error", "Only owners and admins allocate space")
    assert IPAM.list_ip_addresses(context.admin) == []
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
