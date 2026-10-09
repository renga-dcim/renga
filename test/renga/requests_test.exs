defmodule Renga.RequestsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Requests

  setup do
    organization = organization_fixture()
    admin = member_scope(organization, "admin")
    member = member_scope(organization, "member")

    {:ok, resource} =
      Inventory.create_resource(admin, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    {:ok, _host} = Inventory.create_host(admin, resource.id, %{vendor: "Dell"})

    %{organization: organization, admin: admin, member: member, resource: resource}
  end

  describe "creating" do
    test "a member proposes a lifecycle change with the before value", context do
      assert {:ok, request} =
               Requests.request_lifecycle(context.member, context.resource, %{
                 "value" => "retired",
                 "reason" => "Decommissioned in the Q3 refresh"
               })

      assert %{
               kind: "lifecycle",
               status: "open",
               before_value: %{"value" => "active"},
               after_value: %{"value" => "retired"}
             } = request

      assert request.requested_by_user_id == context.member.user.id
      assert Requests.count_open(context.admin) == 1
    end

    test "requires a reason, a real change, and a valid value", context do
      assert {:error, changeset} =
               Requests.request_lifecycle(context.member, context.resource, %{
                 "value" => "retired"
               })

      assert "say why this change is needed" in errors_on(changeset).reason

      assert {:error, changeset} =
               Requests.request_lifecycle(context.member, context.resource, %{
                 "value" => "active",
                 "reason" => "x"
               })

      assert "is already the current value" in errors_on(changeset).after_value

      assert {:error, changeset} =
               Requests.request_lifecycle(context.member, context.resource, %{
                 "value" => "melted",
                 "reason" => "x"
               })

      assert "is not a lifecycle state" in errors_on(changeset).after_value

      assert {:error, :invalid_field} =
               Requests.request_field_override(context.member, context.resource, "name", %{})
    end

    test "keeps one open request per change on a resource", context do
      attrs = %{"value" => "Supermicro", "reason" => "Chassis label"}

      {:ok, _request} =
        Requests.request_field_override(context.member, context.resource, "vendor", attrs)

      other = member_scope(context.organization, "member")

      assert {:error, changeset} =
               Requests.request_field_override(other, context.resource, "vendor", attrs)

      assert "already has an open request" in errors_on(changeset).organization_id

      assert {:ok, _model} =
               Requests.request_field_override(other, context.resource, "model", attrs)
    end

    test "only members request; owners, admins, and viewers cannot", context do
      attrs = %{"value" => "retired", "reason" => "x"}
      viewer = member_scope(context.organization, "viewer")

      assert {:error, :forbidden} =
               Requests.request_lifecycle(context.admin, context.resource, attrs)

      assert {:error, :forbidden} = Requests.request_lifecycle(viewer, context.resource, attrs)
      assert Requests.can_request?(context.member)
      refute Requests.can_request?(context.admin)
    end
  end

  describe "deciding" do
    test "a member can pin the observed value without changing its text", context do
      assert Inventory.list_resource_overrides(context.admin, context.resource.id) == []

      assert {:ok, request} =
               Requests.request_field_override(context.member, context.resource, "vendor", %{
                 "value" => "Dell",
                 "reason" => "Verified chassis label"
               })

      assert request.before_value == request.after_value
      assert {:ok, 1} = Requests.approve(context.admin, request)
      assert [override] = Inventory.list_resource_overrides(context.admin, context.resource.id)
      assert override.value == %{"value" => "Dell"}
      assert override.reason == "Verified chassis label"
      assert override.created_by_user_id == context.admin.user.id
    end

    test "approval applies the change as the approver and records the requester", context do
      {:ok, request} =
        Requests.request_lifecycle(context.member, context.resource, %{
          "value" => "retired",
          "reason" => "Decommissioned"
        })

      :ok = Changes.subscribe(context.admin)
      assert {:ok, 1} = Requests.approve(context.admin, request, "Confirmed with facilities")
      assert_receive {:inventory_changed, _organization_id}

      assert Inventory.get_resource!(context.admin, context.resource.id).lifecycle_state ==
               "retired"

      request = Requests.get_request(context.admin, request.id)
      assert request.status == "approved"
      assert request.decided_by_user_id == context.admin.user.id
      assert request.decision_note == "Confirmed with facilities"

      events = Inventory.list_change_events(context.admin, context.resource.id)
      approved = Enum.find(events, &(&1.kind == "request_approved"))
      assert approved.actor_user_id == context.admin.user.id
      assert approved.metadata["requested_by_user_id"] == context.member.user.id

      assert Enum.any?(
               events,
               &(&1.kind == "request_created" and &1.actor_user_id == context.member.user.id)
             )
    end

    test "approving an override sets it with the requester's reason", context do
      {:ok, request} =
        Requests.request_field_override(context.member, context.resource, "vendor", %{
          "value" => "Supermicro",
          "reason" => "Chassis label says Supermicro"
        })

      assert {:ok, 1} = Requests.approve(context.admin, request)

      assert [%{reason: "Chassis label says Supermicro", value: %{"value" => "Supermicro"}}] =
               Inventory.list_resource_overrides(context.admin, context.resource.id)
    end

    test "similar requests are found and approved together, or not at all", context do
      {:ok, other_resource} =
        Inventory.create_resource(context.admin, %{
          kind: "server",
          name: "web-02",
          lifecycle_state: "active"
        })

      attrs = %{"value" => "retired", "reason" => "Refresh"}
      {:ok, first} = Requests.request_lifecycle(context.member, context.resource, attrs)
      {:ok, second} = Requests.request_lifecycle(context.member, other_resource, attrs)

      {:ok, _different} =
        Requests.request_field_override(context.member, other_resource, "vendor", %{
          "value" => "HPE",
          "reason" => "x"
        })

      assert [similar] = Requests.similar_requests(context.admin, first)
      assert similar.id == second.id

      {:ok, _rejected} = Requests.reject(context.admin, second)
      assert {:error, :closed} = Requests.approve(context.admin, [first, second])
      assert Requests.get_request(context.admin, first.id).status == "open"

      assert Inventory.get_resource!(context.admin, context.resource.id).lifecycle_state ==
               "active"
    end

    test "members cannot approve or reject; only the requester withdraws", context do
      {:ok, request} =
        Requests.request_lifecycle(context.member, context.resource, %{
          "value" => "retired",
          "reason" => "x"
        })

      other = member_scope(context.organization, "member")

      assert {:error, :forbidden} = Requests.approve(context.member, request)
      assert {:error, :forbidden} = Requests.reject(context.member, request)
      assert {:error, :forbidden} = Requests.withdraw(other, request)

      assert {:ok, %{status: "withdrawn"}} = Requests.withdraw(context.member, request)
      assert {:error, :closed} = Requests.approve(context.admin, request)
    end

    test "never reads or decides another organization's requests", context do
      {:ok, request} =
        Requests.request_lifecycle(context.member, context.resource, %{
          "value" => "retired",
          "reason" => "x"
        })

      stranger = member_scope(organization_fixture(), "admin")

      assert Requests.get_request(stranger, request.id) == nil
      assert {[], 0} = Requests.list_requests(stranger)
      assert {:error, :not_found} = Requests.approve(stranger, request)
    end
  end

  describe "expectation requests" do
    test "a member asks one resource to expect another part; approval applies it", context do
      {server, expected} =
        assigned_server_fixture(context.admin, "expect-01", [
          %{
            kind: "memory",
            name: "DIMM A1",
            position: "A1",
            attributes: %{"part_number" => "M-32G"}
          }
        ])

      dimm = expected["DIMM A1"]

      change = %{
        "action" => "alter",
        "component_template_id" => dimm.component_template_id,
        "name" => "DIMM A1",
        "changes" => %{"attributes" => %{"part_number" => "M-64G"}}
      }

      assert {:ok, request} =
               Requests.request_expectation(context.member, server, change, %{
                 "reason" => "Upgraded to 64 GB modules"
               })

      assert request.kind == "expectation"
      assert request.field == "template:" <> dimm.component_template_id
      assert request.before_value == %{"value" => "Part number M-32G in DIMM A1"}
      assert request.after_value["value"] == "Expect Part number M-64G in DIMM A1"

      # The same slot cannot carry two open requests.
      assert {:error, changeset} =
               Requests.request_expectation(context.member, server, change, %{"reason" => "again"})

      assert "already has an open request" in errors_on(changeset).organization_id

      assert {:ok, 1} = Requests.approve(context.admin, [request])
      assert Requests.get_request(context.admin, request.id).status == "approved"

      assert [%{attributes: %{"part_number" => "M-64G"}}] =
               Catalog.list_expected_components(context.admin, server.id)

      assert Catalog.describe_expectation(context.admin, server.id, request.field) ==
               "Part number M-64G in DIMM A1"
    end

    test "names a part a resource should newly expect and rejects malformed changes", context do
      {server, _expected} = assigned_server_fixture(context.admin, "expect-02", [])

      assert {:ok, request} =
               Requests.request_expectation(
                 context.member,
                 server,
                 %{"action" => "add", "kind" => "disk", "name" => "Bay 9", "changes" => %{}},
                 %{"reason" => "Extra disk for logs"}
               )

      assert request.field == "component:disk:bay 9"
      assert request.after_value["value"] == "Expect Bay 9"
      assert {:ok, 1} = Requests.approve(context.admin, [request])

      assert [%{kind: "disk", name: "Bay 9"}] =
               Catalog.list_expected_components(context.admin, server.id)

      assert {:error, :invalid_expectation} =
               Requests.request_expectation(context.member, server, %{"action" => "alter"}, %{
                 "reason" => "x"
               })
    end

    test "asks to undo a local change, returning the slot to the catalog", context do
      {server, expected} =
        assigned_server_fixture(context.admin, "expect-03", [
          %{kind: "disk", name: "Bay 1", position: "1", attributes: %{"model" => "SSD-1"}}
        ])

      template_id = expected["Bay 1"].component_template_id

      {:ok, exception} =
        Catalog.put_expected_component_exception(context.admin, server.id, %{
          "action" => "suppress",
          "component_template_id" => template_id
        })

      change = %{
        "action" => "restore",
        "exception_id" => exception.id,
        "component_template_id" => template_id,
        "name" => "Bay 1"
      }

      assert {:ok, request} =
               Requests.request_expectation(context.member, server, change, %{
                 "reason" => "The bay is populated again"
               })

      assert request.field == "template:" <> template_id
      assert request.before_value == %{"value" => "Not expected: Bay 1"}
      assert request.after_value["value"] == "Expect Bay 1 as the catalog defines it"
      assert {:ok, 1} = Requests.approve(context.admin, [request])

      assert [%{suppressed: false, exception_id: nil}] =
               Catalog.list_expected_components(context.admin, server.id)

      # Undoing a change that is already gone fails instead of approving nothing.
      assert {:ok, again} =
               Requests.request_expectation(context.member, server, change, %{"reason" => "x"})

      assert {:error, :not_found} = Requests.approve(context.admin, [again])
    end
  end

  defp member_scope(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Renga.Accounts.scope_for_user(user, organization.id)
  end
end
