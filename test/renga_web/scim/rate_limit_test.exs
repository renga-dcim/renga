defmodule RengaWeb.Scim.RateLimitTest do
  # Changes the application's rate limit, so it runs alone.
  use RengaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  setup %{conn: conn} do
    owner = member_scope(organization_fixture(), "owner")
    {_token, value} = scim_token_fixture(owner, scim_connection_fixture(owner))
    %{conn: put_req_header(conn, "authorization", "Bearer " <> value), value: value}
  end

  test "a connection over its limit gets 429 with Retry-After", %{conn: conn} do
    previous = Application.get_env(:renga, RengaWeb.Scim.RateLimit)
    Application.put_env(:renga, RengaWeb.Scim.RateLimit, requests_per_minute: 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:renga, RengaWeb.Scim.RateLimit, previous),
        else: Application.delete_env(:renga, RengaWeb.Scim.RateLimit)
    end)

    assert get(conn, ~p"/scim/v2/ServiceProviderConfig").status == 200

    # A minute boundary between requests opens a fresh window, so allow for
    # one: five requests always include a third in one window.
    refused =
      Enum.find_value(1..5, fn _ ->
        conn = get(conn, ~p"/scim/v2/ServiceProviderConfig")
        if conn.status == 429, do: conn
      end)

    assert %Plug.Conn{} = conn = refused
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end

  test "the token never reaches the log", %{conn: conn, value: value} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log(fn -> get(conn, ~p"/scim/v2/ServiceProviderConfig") end)

    assert log =~ "/scim/v2/ServiceProviderConfig"
    refute log =~ value
  end
end
