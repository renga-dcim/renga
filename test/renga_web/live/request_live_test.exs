defmodule RengaWeb.RequestLiveTest do
  @moduledoc """
  Member requests end to end: a member proposes from the resource page, an
  owner or admin decides from the Inbox.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Requests

  setup do
    organization = organization_fixture()
    {admin, admin_scope} = member(organization, "admin")
    {member, member_scope} = member(organization, "member")

    {:ok, resource} =
      Inventory.create_resource(admin_scope, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    {:ok, _host} = Inventory.create_host(admin_scope, resource.id, %{vendor: "Dell"})

    %{
      organization: organization,
      admin_conn: log_in(admin, organization),
      member_conn: log_in(member, organization),
      admin: admin_scope,
      member: member_scope,
      resource: resource
    }
  end

  test "a member requests a lifecycle change and can withdraw it", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/inventory/#{context.resource}")

    refute has_element?(view, "#resource-lifecycle-form")

    view
    |> form("#resource-lifecycle-request-form", request: %{value: "retired", reason: ""})
    |> render_submit()

    assert has_element?(view, "#resource-lifecycle-request-form", "say why this change is needed")

    view
    |> form("#resource-lifecycle-request-form",
      request: %{value: "retired", reason: "Decommissioned in the refresh"}
    )
    |> render_submit()

    assert has_element?(view, "#resource-lifecycle-request", "retired")
    assert has_element?(view, "#resource-lifecycle-request", context.member.user.email)
    refute has_element?(view, "#resource-lifecycle-request-form")

    view |> element("#resource-lifecycle-request-withdraw") |> render_click()

    refute has_element?(view, "#resource-lifecycle-request")
    assert Requests.count_open(context.admin) == 0
  end

  test "a member requests an override from a value's provenance panel", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/inventory/#{context.resource}")

    refute has_element?(view, "#override-vendor-form")

    view
    |> form("#override-vendor-request-form",
      request: %{value: "Supermicro", reason: "Chassis label says Supermicro"}
    )
    |> render_submit()

    assert has_element?(view, "#override-vendor-request", "Supermicro")
    assert has_element?(view, "#property-vendor", "Dell")
  end

  test "owners and admins apply changes directly and see no request forms", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inventory/#{context.resource}")

    assert has_element?(view, "#resource-lifecycle-form")
    refute has_element?(view, "#resource-lifecycle-request-form")
    refute has_element?(view, "#override-vendor-request-form")
  end

  test "an admin reviews and approves a request from the Inbox", context do
    {:ok, request} =
      Requests.request_lifecycle(context.member, context.resource, %{
        "value" => "retired",
        "reason" => "Decommissioned in the refresh"
      })

    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox")

    assert has_element?(view, "#inbox-group-requests", "1")

    assert has_element?(
             view,
             "#inbox-requests-preview #requests-#{request.id}",
             "Lifecycle → retired"
           )

    view |> element("#requests-#{request.id} td:first-child") |> render_click()

    assert has_element?(view, "#request-change", "active")
    assert has_element?(view, "#request-change", "retired")
    assert has_element?(view, "#request-reason", "Decommissioned in the refresh")
    assert has_element?(view, "#request-properties", context.member.user.email)

    view
    |> form("#request-decision-form", decision_form: %{note: "Confirmed"})
    |> put_submitter("#request-approve")
    |> render_submit()

    assert has_element?(view, "#request-status", "approved")

    assert Inventory.get_resource!(context.admin, context.resource.id).lifecycle_state ==
             "retired"

    refute has_element?(view, "#inbox-requests-preview")
    assert has_element?(view, "#inbox-group-requests", "0")

    {:ok, activity, _html} = live(context.admin_conn, ~p"/activity")

    assert has_element?(
             activity,
             "#activity-events",
             "Approved request: lifecycle state → retired"
           )

    assert has_element?(activity, "#activity-events", "Requested lifecycle state → retired")
  end

  test "the same change on several resources can be approved together", context do
    {:ok, other} =
      Inventory.create_resource(context.admin, %{
        kind: "server",
        name: "web-02",
        lifecycle_state: "active"
      })

    attrs = %{"value" => "retired", "reason" => "Refresh"}
    {:ok, first} = Requests.request_lifecycle(context.member, context.resource, attrs)
    {:ok, _second} = Requests.request_lifecycle(context.member, other, attrs)

    {:ok, view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[group: "requests", request: first.id]}")

    assert has_element?(view, "#request-similar", "1 other resource")
    assert has_element?(view, "#request-similar", "web-02")

    view
    |> form("#request-decision-form")
    |> put_submitter("#request-approve-all")
    |> render_submit()

    assert render(view) =~ "2 requests approved"
    assert Inventory.get_resource!(context.admin, other.id).lifecycle_state == "retired"
    assert has_element?(view, "#requests-empty")
  end

  test "a rejection keeps the resource unchanged and records the note", context do
    {:ok, request} =
      Requests.request_field_override(context.member, context.resource, "vendor", %{
        "value" => "Supermicro",
        "reason" => "Label"
      })

    {:ok, view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[group: "requests", request: request.id]}")

    view
    |> form("#request-decision-form", decision_form: %{note: "BMC reports Dell"})
    |> put_submitter("#request-reject")
    |> render_submit()

    assert has_element?(view, "#request-status", "rejected")
    assert has_element?(view, "#request-decision-note", "BMC reports Dell")
    assert Inventory.list_resource_overrides(context.admin, context.resource.id) == []

    {:ok, rejected, _html} = live(context.admin_conn, ~p"/inbox?group=requests&status=rejected")
    assert has_element?(rejected, "#requests-#{request.id} [data-status=rejected]")
  end

  test "members cannot decide requests, even with forged events", context do
    {:ok, request} =
      Requests.request_lifecycle(context.member, context.resource, %{
        "value" => "retired",
        "reason" => "x"
      })

    {_other, other_scope} = member(context.organization, "member")
    other_conn = log_in(other_scope.user, context.organization)

    {:ok, view, _html} = live(other_conn, ~p"/inbox?#{[group: "requests", request: request.id]}")

    refute has_element?(view, "#request-decision-form")
    refute has_element?(view, "#request-withdraw")
    assert has_element?(view, "#request-decision-unavailable")

    assert render_submit(view, "decide", %{"decision" => "approve"}) =~
             "Only owners and admins decide requests"

    assert Inventory.get_resource!(context.admin, context.resource.id).lifecycle_state == "active"
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    {user, Renga.Accounts.scope_for_user(user, organization.id)}
  end

  defp log_in(user, organization) do
    build_conn()
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end
end
