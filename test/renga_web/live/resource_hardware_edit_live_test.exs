defmodule RengaWeb.ResourceHardwareEditLiveTest do
  @moduledoc """
  The Hardware tab's slot comparison and the "what happened?" answers
  (RFD 8, "Editing hardware components").
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Requests

  @dimms for slot <- ~w(A1 A2 A3 A4 A5),
             do: %{
               kind: "memory",
               name: "DIMM #{slot}",
               position: slot,
               attributes: %{"part_number" => "M-32G"}
             }

  @disk %{kind: "disk", name: "Bay 1", position: "Bay 1", attributes: %{"model" => "SSD-960"}}

  setup %{conn: conn} do
    organization = organization_fixture()
    admin = scope_for(organization, "admin")

    {server, expected} = assigned_server_fixture(admin, "hw-edit", @dimms ++ [@disk])

    for slot <- ~w(A1 A2 A3 A4),
        do: actual_component_fixture(admin, server, "memory", slot, part_number: "M-32G")

    actual_component_fixture(admin, server, "disk", "Bay 1", model: "SSD-1920")
    stray = actual_component_fixture(admin, server, "memory", "A6", part_number: "M-16G")

    %{
      conn: log_in(conn, admin, organization),
      organization: organization,
      admin: admin,
      server: server,
      expected: expected,
      stray: stray
    }
  end

  test "compares slot by slot, collapsing runs of matches", context do
    {:ok, view, _html} = live(context.conn, hardware_path(context.server))

    a1 = slot(context.expected, "DIMM A1")
    assert has_element?(view, "#run-#{a1}", "A1 – A4")
    assert has_element?(view, "#run-#{a1}", "4 match")
    assert has_element?(view, "#run-#{a1} ##{a1}[data-state=match]")

    assert has_element?(
             view,
             "##{slot(context.expected, "DIMM A5")}[data-state=missing]",
             "Missing"
           )

    assert has_element?(view, "#slot-actual-#{context.stray.id}", "Not expected")
    assert has_element?(view, "##{slot(context.expected, "Bay 1")}", "Different part")
    assert has_element?(view, "#hardware-summary", "missing")
  end

  test "drift shows each differing field in the slot panel", context do
    {:ok, view, _html} = live(context.conn, hardware_path(context.server))

    view |> element("##{slot(context.expected, "Bay 1")}") |> render_click()

    assert has_element?(view, "#slot-panel", "A different part is reported")
    assert has_element?(view, "#slot-field-model[data-differs=true]", "SSD-1920")
    assert has_element?(view, "#slot-intent-replacement")
    assert has_element?(view, "#slot-intent-expect")
    refute has_element?(view, "#slot-intent-gap")
  end

  test "a missing part can be accepted as out until a date", context do
    a5 = slot(context.expected, "DIMM A5")
    {:ok, view, _html} = live(context.conn, hardware_path(context.server, a5))

    view |> element("#slot-intent-gap") |> render_click()

    view
    |> form("#gap-form", gap: %{until: Date.to_iso8601(Date.utc_today()), reason: ""})
    |> render_submit()

    assert has_element?(view, "#gap-form", "explain why")

    until = Date.add(Date.utc_today(), 3)

    view
    |> form("#gap-form", gap: %{until: Date.to_iso8601(until), reason: "RMA in progress"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "out until")
    refute has_element?(view, "#slot-panel")
    assert has_element?(view, "##{a5}", "Out until #{Calendar.strftime(until, "%b %-d")}")
  end

  test "a replacement waits for a collector, then matches", context do
    a5 = slot(context.expected, "DIMM A5")
    {:ok, view, _html} = live(context.conn, hardware_path(context.server, a5, "replacement"))

    view
    |> form("#replacement-form", replacement: %{part_number: "", serial_number: "", model: ""})
    |> render_submit()

    assert has_element?(view, "#replacement-form", "enter a part number")

    view
    |> form("#replacement-form", replacement: %{part_number: "M-64G", serial_number: "S-9"})
    |> render_submit()

    assert has_element?(view, "##{a5}", "Replacement pending")

    actual_component_fixture(context.admin, context.server, "memory", "A5", part_number: "M-64G")
    send(view.pid, :reload)

    assert has_element?(view, "##{a5}[data-state=match]")
  end

  test "owners and admins change what one resource expects and can undo it", context do
    disk = slot(context.expected, "Bay 1")
    {:ok, view, _html} = live(context.conn, hardware_path(context.server, disk, "expect"))

    # The form starts from the part the collector reported.
    view |> form("#expect-form") |> render_submit()

    assert has_element?(view, "##{disk}", "Changed here")

    assert [%{attributes: %{"model" => "SSD-1920"}}] =
             context.admin
             |> Catalog.list_expected_components(context.server.id)
             |> Enum.filter(&(&1.kind == "disk"))

    {:ok, view, _html} = live(context.conn, hardware_path(context.server, disk, "restore"))
    view |> form("#restore-form") |> render_submit()

    assert has_element?(view, "##{disk}", "Different part")
  end

  test "a part nothing expects can become expected on this resource", context do
    {:ok, view, _html} =
      live(context.conn, hardware_path(context.server, "actual:#{context.stray.id}", "expect"))

    view |> form("#expect-form") |> render_submit()

    refute has_element?(view, "#slot-actual-#{context.stray.id}")

    added =
      context.admin
      |> Catalog.list_expected_components(context.server.id)
      |> Enum.find(&(&1.position == "A6"))

    assert added.attributes == %{"part_number" => "M-16G"}
    # Only this resource expects it, so the slot reads as a local change.
    assert has_element?(view, "#slot-exception-#{added.exception_id}", "Changed here")
  end

  test "members request expectation changes instead of applying them", context do
    member = scope_for(context.organization, "member")
    conn = log_in(build_conn(), member, context.organization)
    a5 = slot(context.expected, "DIMM A5")

    {:ok, view, _html} = live(conn, hardware_path(context.server, a5, "expect"))
    assert has_element?(view, "#expect-save", "Request change")

    view |> form("#expect-form", expect: %{action: "suppress"}) |> render_change()
    refute has_element?(view, "#expect-form input[name='expect[part_number]']")

    view |> form("#expect-form", expect: %{action: "suppress", reason: ""}) |> render_submit()
    assert has_element?(view, "#expect-form [role=alert]")

    view
    |> form("#expect-form", expect: %{action: "suppress", reason: "Bank A5 is unpopulated"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "requested")
    assert has_element?(view, "##{a5}", "Missing")
    assert {[request], 1} = Requests.list_requests(context.admin, resource_id: context.server.id)
    assert request.after_value["value"] == "Stop expecting DIMM A5"

    {:ok, view, _html} = live(conn, hardware_path(context.server, a5))
    assert has_element?(view, "#slot-request", "Stop expecting DIMM A5")
    refute has_element?(view, "#slot-intent-expect")
    assert has_element?(view, "#slot-intent-gap")
  end

  test "viewers read slots but cannot answer, even with forged events", context do
    viewer = scope_for(context.organization, "viewer")
    conn = log_in(build_conn(), viewer, context.organization)
    a5 = slot(context.expected, "DIMM A5")

    {:ok, view, _html} = live(conn, hardware_path(context.server, a5, "gap"))

    assert has_element?(view, "#slot-panel")
    assert has_element?(view, "#slot-read-only")
    refute has_element?(view, "#slot-intents")
    refute has_element?(view, "#gap-form")

    render_hook(view, "accept_gap", %{"gap" => %{"until" => "2099-01-01", "reason" => "x"}})
    render_hook(view, "change_expectation", %{"expect" => %{"action" => "suppress"}})

    assert Renga.Findings.component_exceptions(context.admin, context.server.id) == %{}
    assert {[], 0} = Requests.list_requests(context.admin, resource_id: context.server.id)
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp log_in(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end

  defp slot(expected, name), do: "slot-template-#{expected[name].component_template_id}"

  defp hardware_path(resource), do: ~p"/inventory/#{resource}/hardware"

  # Takes a slot's DOM id or its key.
  defp hardware_path(resource, slot, intent \\ nil) do
    key =
      case slot do
        "slot-template-" <> id -> "template:" <> id
        key -> key
      end

    query = Enum.reject([component: key, intent: intent], &is_nil(elem(&1, 1)))
    ~p"/inventory/#{resource}/hardware?#{query}"
  end
end
