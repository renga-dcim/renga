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

  test "offers the account's passkeys", %{conn: conn, user: user} do
    authenticator = Renga.FakeAuthenticator.new()
    options = Renga.Accounts.passkey_registration_options(user)

    {:ok, _passkey} =
      Renga.Accounts.Passkeys.register(
        user,
        Renga.FakeAuthenticator.register(authenticator, options)
      )

    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    {:ok, lv, _html} = live(recycle(conn), ~p"/users/log-in/second-step")

    assert has_element?(lv, "#second_step_passkey_form[data-mode=get]")

    assert lv |> element("#second_step_passkey_form") |> render() =~
             Base.url_encode64(authenticator.credential_id, padding: false)
  end

  test "without a half-finished sign-in it goes back to signing in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/log-in/second-step")
  end
end
