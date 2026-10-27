defmodule RengaWeb.DeletionControllerTest do
  use RengaWeb.ConnCase, async: true
  import Renga.JobsFixtures
  alias Renga.Operators.OrganizationLifecycle, as: Lifecycle

  test "authenticated pending-deletion owners can export and cancel without opening inventory", %{
    conn: conn
  } do
    %{organization: organization, scope: scope} = job_organization_fixture()

    {:ok, _} =
      Lifecycle.change(
        organization.id,
        "schedule_deletion",
        Renga.DeploymentAudit.operator("test")
      )

    conn = log_in_user(conn, scope.user)
    page = get(conn, "/organizations/deletions")

    assert html_response(page, 200)
           |> LazyHTML.from_document()
           |> LazyHTML.query("#cancel-deletion-#{organization.id}")
           |> Enum.count() == 1

    response = post(conn, "/organizations/deletions/#{organization.id}/export")
    assert redirected_to(response) == "/organizations/deletions"
    assert {:ok, recovery_scope} = Lifecycle.owner_scope(scope.user, organization.id)
    assert {:ok, [export]} = Renga.Transfers.list_exports(recovery_scope)
    assert export.status == "ready"
    download = get(conn, "/organizations/deletions/#{organization.id}/exports/#{export.id}")
    assert download.status == 200
    assert byte_size(download.resp_body) > 0
    response = post(conn, "/organizations/deletions/#{organization.id}/cancel")
    assert redirected_to(response) == "/organizations/deletions"
    assert Renga.Accounts.get_organization!(organization.id).status == "active"
  end
end
