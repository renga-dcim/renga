defmodule RengaWeb.UserLive.SecondStepTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures

  setup do
    user = set_password(user_fixture())
    {secret, codes} = totp_fixture(user)
    %{user: user, secret: secret, codes: codes}
  end

  test "asks for the code after the password", %{conn: conn, user: user} do
    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    {:ok, _lv, html} = live(recycle(conn), ~p"/users/log-in/second-step")

    assert html =~ "Confirm it&#39;s you"
    assert html =~ user.email
    assert html =~ "recovery codes"
  end

  test "without a half-finished sign-in it goes back to signing in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/log-in/second-step")
  end
end
