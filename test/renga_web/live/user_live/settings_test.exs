defmodule RengaWeb.UserLive.SettingsTest do
  use RengaWeb.ConnCase, async: true

  alias Renga.Accounts
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "opens long after signing in, without signing in again", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(Renga.Time.utc_now_ms(), -3, :day)
        )
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture() |> set_password()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "asks for the password in place, then sends the confirmation link", %{
      conn: conn,
      user: user
    } do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{"user" => %{"email" => new_email}})
        |> render_submit()

      assert result =~ "Confirm it&#39;s you"
      refute result =~ "A link to confirm your email"

      result =
        lv
        |> form("#recheck_form", %{"recheck" => %{"password" => valid_user_password()}})
        |> render_submit()

      assert result =~ "A link to confirm your email"
      refute has_element?(lv, "#recheck")
      assert Accounts.get_user_by_email(user.email)
    end

    test "a passing check covers the next change without asking again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#email_form", %{"user" => %{"email" => unique_user_email()}}) |> render_submit()

      lv
      |> form("#recheck_form", %{"recheck" => %{"password" => valid_user_password()}})
      |> render_submit()

      result =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert result =~ "A link to confirm your email"
      refute has_element?(lv, "#recheck")
    end

    test "a wrong password changes nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#email_form", %{"user" => %{"email" => unique_user_email()}}) |> render_submit()

      result =
        lv
        |> form("#recheck_form", %{"recheck" => %{"password" => "not the password"}})
        |> render_submit()

      assert result =~ "That password isn&#39;t right."
      refute result =~ "A link to confirm your email"
    end

    test "an account without a password must set one first", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert result =~ "Set a password first."
      refute has_element?(lv, "#recheck_form")
      refute has_element?(lv, "#bootstrap_send")
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "sets the first password after an emailed code", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert render_submit(form) =~ "Your account has no password yet."

      lv |> element("#bootstrap_send") |> render_click()
      assert_received {:email, %{subject: "Your Renga confirmation code", text_body: body}}
      [code] = Regex.run(~r/[A-Z0-9]{5}-[A-Z0-9]{5}/, body)

      lv
      |> form("#bootstrap_form", %{"recheck" => %{"code" => String.downcase(code)}})
      |> render_submit()

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "a wrong code does not set the password", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#password_form", %{
        "user" => %{
          "password" => valid_user_password(),
          "password_confirmation" => valid_user_password()
        }
      })
      |> render_submit()

      lv |> element("#bootstrap_send") |> render_click()

      result =
        lv
        |> form("#bootstrap_form", %{"recheck" => %{"code" => "AAAAA-AAAAA"}})
        |> render_submit()

      assert result =~ "That code isn&#39;t right."
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "changing an existing password asks for the current one", %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)
      new_password = "a brand new password"

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)
      refute has_element?(lv, "#bootstrap_send")

      lv
      |> form("#recheck_form", %{"recheck" => %{"password" => valid_user_password()}})
      |> render_submit()

      new_password_conn = follow_trigger_action(form, conn)
      assert redirected_to(new_password_conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
