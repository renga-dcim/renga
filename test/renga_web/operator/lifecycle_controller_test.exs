defmodule RengaWeb.Operator.LifecycleControllerTest do
  use RengaWeb.OperatorCase, async: true

  test "lifecycle endpoints are retryable, scoped, and report the stable deadline", %{conn: conn} do
    organization = Renga.InventoryFixtures.organization_fixture()
    {_token, plaintext} = operator_token_fixture(%{scopes: ["organizations:write"]})
    conn = authorize(conn, plaintext)
    base = "/operator/v1/organizations/#{organization.id}"

    assert %{"status" => "disabled"} =
             conn |> post(base <> "/suspend") |> valid_operator_response(200)

    first = conn |> post(base <> "/schedule-deletion") |> valid_operator_response(200)
    repeated = conn |> post(base <> "/schedule-deletion") |> valid_operator_response(200)
    assert first["deletion_due_at"] == repeated["deletion_due_at"]
    assert first["status"] == "deletion_pending"

    assert %{"status" => "active", "deletion_due_at" => nil} =
             conn |> post(base <> "/cancel-deletion") |> valid_operator_response(200)

    assert %{"status" => "active"} =
             conn |> post(base <> "/resume") |> valid_operator_response(200)

    {_read_token, read_plaintext} = operator_token_fixture(%{scopes: ["organizations:read"]})

    assert %{"error" => "forbidden"} =
             Phoenix.ConnTest.build_conn()
             |> authorize(read_plaintext)
             |> post(base <> "/suspend")
             |> valid_operator_response(403)
  end
end
