defmodule RengaWeb.Scim.RequestLogTest do
  # Not async: the test lowers the global logger level, since the router's
  # dispatch log is what would print a password.
  use RengaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  setup %{conn: conn} do
    owner = member_scope(organization_fixture(), "owner")
    connection = scim_connection_fixture(owner)
    {_token, value} = scim_token_fixture(owner, connection)

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> value)
      |> put_req_header("content-type", "application/scim+json")

    %{conn: conn}
  end

  test "a SCIM password never reaches the request log", %{conn: conn} do
    log =
      capture_log([level: :debug], fn ->
        created =
          conn
          |> post(
            ~p"/scim/v2/Users",
            Jason.encode!(%{"userName" => "sam", "Password" => "Cr3ate!"})
          )
          |> json_response(201)

        conn
        |> patch(
          ~p"/scim/v2/Users/#{created["id"]}",
          Jason.encode!(%{
            "Operations" => [%{"op" => "replace", "path" => "password", "value" => "Patch3d!"}]
          })
        )
        |> json_response(400)
      end)

    refute log =~ "Cr3ate!"
    refute log =~ "Patch3d!"
  end
end
