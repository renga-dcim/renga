defmodule RengaWeb.UserSessionControllerTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query

  import Renga.AccountsFixtures
  alias Renga.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  defp sign_in_methods(user) do
    for %{kind: "signed_in", metadata: %{"method" => method}} <-
          Accounts.list_security_events(user),
        do: method
  end

  defp second_factor?(conn) do
    {user, _inserted_at} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    Accounts.SessionMFA.second_factor?(user.session_mfa)
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert sign_in_methods(user) == ["password"]
      refute second_factor?(conn)

      # Root dispatches the new session into organization onboarding.
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/organizations"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_renga_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Root dispatches the new session into organization onboarding.
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/organizations"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Root dispatches the new session into organization onboarding.
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/organizations"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "second step for an account with MFA" do
    setup %{user: user} do
      user = set_password(user)
      {secret, codes} = totp_fixture(user)
      %{user: user, secret: secret, codes: codes}
    end

    defp sign_in_with_password(conn, user, extra \\ %{}) do
      post(conn, ~p"/users/log-in", %{
        "user" => Map.merge(%{"email" => user.email, "password" => valid_user_password()}, extra)
      })
    end

    test "a password is only the first step", %{conn: conn, user: user} do
      conn = sign_in_with_password(conn, user)

      assert redirected_to(conn) == ~p"/users/log-in/second-step"
      refute get_session(conn, :user_token)
      assert sign_in_methods(user) == []
    end

    # A browser that was signed in, as anyone, holds no live session while
    # its next sign-in waits for the second step.
    test "starting a sign-in ends the browser's earlier session", %{conn: conn, user: user} do
      other = user_fixture()
      earlier = Renga.Accounts.generate_user_session_token(other)

      conn =
        conn
        |> init_test_session(%{user_token: earlier})
        |> sign_in_with_password(user)

      assert redirected_to(conn) == ~p"/users/log-in/second-step"
      refute get_session(conn, :user_token)
      refute Renga.Accounts.get_user_by_session_token(earlier)
      assert %{max_age: 0} = conn.resp_cookies["_renga_web_user_remember_me"]
    end

    test "a magic link is only the first step", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == ~p"/users/log-in/second-step"
      refute get_session(conn, :user_token)
    end

    test "an authenticator code finishes signing in", %{conn: conn, user: user, secret: secret} do
      conn = sign_in_with_password(conn, user, %{"remember_me" => "true"})

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert get_session(conn, :user_token)
      refute get_session(conn, :pending_second_step)
      assert sign_in_methods(user) == ["totp"]
      assert second_factor?(conn)
      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["_renga_web_user_remember_me"]
    end

    test "a wrong code signs nobody in", %{conn: conn, user: user, secret: secret} do
      conn = sign_in_with_password(conn, user)

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => wrong_totp_code(secret)}
        })

      assert redirected_to(conn) == ~p"/users/log-in/second-step"
      refute get_session(conn, :user_token)
    end

    test "the half-finished sign-in expires", %{conn: conn, user: user, secret: secret} do
      conn = sign_in_with_password(conn, user)
      age_pending_sign_ins(user, -6)

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    # The pending sign-in lives in the signed cookie, which a browser can
    # replay. Its server-side record is spent on completion, so a saved copy
    # finishes nothing, and does not spend the code it is given.
    test "a copied half-finished sign-in cannot finish twice", %{
      conn: conn,
      user: user,
      codes: [first, second | _]
    } do
      pending = sign_in_with_password(conn, user) |> recycle()

      done = post(pending, ~p"/users/log-in/second-step", %{"second_step" => %{"code" => first}})
      assert get_session(done, :user_token)

      replay =
        post(pending, ~p"/users/log-in/second-step", %{"second_step" => %{"code" => second}})

      assert redirected_to(replay) == ~p"/users/log-in"
      refute get_session(replay, :user_token)
      assert Accounts.MFA.recovery_codes_left(user) == 9
      assert sign_in_methods(user) == ["recovery_code"]
    end

    test "a password change ends a half-finished sign-in", %{
      conn: conn,
      user: user,
      secret: secret
    } do
      pending = sign_in_with_password(conn, user) |> recycle()

      {:ok, _} =
        Accounts.update_user_password(user, %{
          password: "a brand new password",
          password_confirmation: "a brand new password"
        })

      conn =
        post(pending, ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "changing the account's factors ends a half-finished sign-in", %{
      conn: conn,
      user: user
    } do
      pending = sign_in_with_password(conn, user) |> recycle()
      {:ok, _user} = Accounts.MFA.disable_totp(user)
      {secret, _codes} = totp_fixture(user)

      conn =
        post(pending, ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "a recovery code signs in to replace the app", %{
      conn: conn,
      user: user,
      codes: [code | _]
    } do
      conn = sign_in_with_password(conn, user)

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{"second_step" => %{"code" => code}})

      token = get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.recovering?(user, token)
      assert second_factor?(conn)
      refute Accounts.authorized_account_change?(user, token, :remove_factor)
      assert Accounts.MFA.recovery_codes_left(user) == 9
    end

    test "changing the password does not ask for the second step again", %{
      conn: conn,
      user: user,
      secret: secret
    } do
      conn = log_in_user(conn, user)

      :ok =
        Accounts.recheck_with_totp(
          user,
          get_session(conn, :user_token),
          NimbleTOTP.verification_code(secret)
        )

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)
    end

    test "the session after a password change keeps the second factor", %{
      conn: conn,
      user: user,
      secret: secret
    } do
      conn =
        conn
        |> log_in_user(user, mfa: Accounts.SessionMFA.for_method(:totp))
        |> tap(fn conn ->
          :ok =
            Accounts.recheck_with_totp(
              user,
              get_session(conn, :user_token),
              NimbleTOTP.verification_code(secret)
            )
        end)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert second_factor?(conn)
    end
  end

  describe "passkeys" do
    alias Renga.Accounts.Passkeys
    alias Renga.FakeAuthenticator

    setup %{user: user} do
      authenticator = FakeAuthenticator.new()
      response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))
      {:ok, _passkey} = Passkeys.register(user, response)
      %{authenticator: authenticator}
    end

    test "a passkey signs in by itself", %{conn: conn, user: user, authenticator: authenticator} do
      response = FakeAuthenticator.assert(authenticator, Accounts.passkey_sign_in_options())

      conn =
        post(conn, ~p"/users/log-in/passkey", %{
          "passkey" => %{"response" => Jason.encode!(response)}
        })

      assert redirected_to(conn) == ~p"/"

      assert {signed_in, _inserted_at} =
               Accounts.get_user_by_session_token(get_session(conn, :user_token))

      assert signed_in.id == user.id
      assert sign_in_methods(user) == ["passkey"]
      assert second_factor?(conn)
    end

    test "a bad passkey response signs nobody in", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in/passkey", %{"passkey" => %{"response" => "{}"}})

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "a passkey completes the second step", %{
      conn: conn,
      user: user,
      authenticator: authenticator
    } do
      {token, _hashed} = generate_user_magic_link_token(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})
      assert redirected_to(conn) == ~p"/users/log-in/second-step"

      response =
        FakeAuthenticator.assert(authenticator, Accounts.passkey_options(user, "second_step"))

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"passkey" => Jason.encode!(response)}
        })

      assert get_session(conn, :user_token)
    end

    test "another account's passkey cannot complete the second step", %{
      conn: conn,
      authenticator: authenticator
    } do
      other = user_fixture()
      totp_fixture(other)
      {token, _hashed} = generate_user_magic_link_token(other)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      response =
        FakeAuthenticator.assert(authenticator, Accounts.passkey_options(other, "second_step"))

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"passkey" => Jason.encode!(response)}
        })

      refute get_session(conn, :user_token)
    end
  end

  describe "registering with only a passkey" do
    test "confirming the email can grant the bootstrap to add a passkey", %{
      conn: conn,
      unconfirmed_user: user
    } do
      {token, _hashed} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in?_action=confirmed", %{
          "user" => %{"token" => token, "add_passkey" => "true"}
        })

      assert redirected_to(conn) == ~p"/users/settings#passkey_register"
      assert sign_in_methods(user) == ["magic_link"]
      session_token = get_session(conn, :user_token)
      assert Accounts.authorized_account_change?(user, session_token, :add_factor)
      refute Accounts.authorized_account_change?(user, session_token, :change_email)
    end

    test "an account that already has a credential gets no bootstrap", %{conn: conn, user: user} do
      user = set_password(user)
      {token, _hashed} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"token" => token, "add_passkey" => "true"}})

      assert redirected_to(conn) == ~p"/"

      refute Accounts.authorized_account_change?(
               user,
               get_session(conn, :user_token),
               :add_factor
             )
    end
  end

  describe "registering with only a passkey, once the account has a factor" do
    test "an account with an authenticator app still takes the second step", %{
      conn: conn,
      user: user
    } do
      totp_fixture(user)
      {token, _hashed} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token, "add_passkey" => "true", "remember_me" => "true"}
        })

      assert redirected_to(conn) == ~p"/users/log-in/second-step"
      refute get_session(conn, :user_token)
      refute conn.resp_cookies["_renga_web_user_remember_me"][:value]

      refute Renga.Repo.exists?(
               from t in Accounts.UserToken,
                 where: t.user_id == ^user.id and t.context == "session"
             )
    end

    test "falling back keeps where the person was going", %{conn: conn, user: user} do
      user = set_password(user)
      {token, _hashed} = generate_user_magic_link_token(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{"user" => %{"token" => token, "add_passkey" => "true"}})

      assert redirected_to(conn) == "/foo/bar"
    end

    test "staying signed in follows the person's choice", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in?_action=confirmed", %{
          "user" => %{"token" => token, "add_passkey" => "true"}
        })

      assert get_session(conn, :user_token)
      refute conn.resp_cookies["_renga_web_user_remember_me"]
    end
  end

  describe "POST /users/update-password" do
    setup %{conn: conn, user: user} do
      user = set_password(user)
      %{conn: log_in_user(conn, user), user: user}
    end

    @new_password "a brand new password"

    test "refuses a change without the account re-check", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => @new_password,
            "password_confirmation" => @new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm it's you"
      refute Accounts.get_user_by_email_and_password(user.email, @new_password)
    end

    test "changes the password after the re-check", %{conn: conn, user: user} do
      :ok =
        Accounts.recheck_with_password(
          user,
          get_session(conn, :user_token),
          valid_user_password()
        )

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => @new_password,
            "password_confirmation" => @new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
    end
  end

  describe "organization after log in" do
    import Renga.InventoryFixtures

    setup %{user: user} do
      user = set_password(user)
      first = organization_fixture()
      second = organization_fixture()
      organization_membership_fixture(user, first, %{role: "owner"})
      organization_membership_fixture(user, second, %{role: "owner"})
      %{user: user, first: first, second: second}
    end

    defp log_in_with_password(conn, user) do
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })
    end

    defp open_then_log_out(conn, user, organization) do
      conn
      |> log_in_with_password(user)
      |> post(~p"/organizations/select", %{"organization" => %{"id" => organization.id}})
      |> delete(~p"/users/log-out")
    end

    test "reopens the organization opened before logging out", %{
      conn: conn,
      user: user,
      second: second
    } do
      conn = log_in_with_password(conn, user)
      assert redirected_to(get(conn, ~p"/")) == ~p"/organizations"

      conn = conn |> open_then_log_out(user, second) |> log_in_with_password(user)

      assert get_session(conn, :current_organization_id) == second.id
      assert redirected_to(get(conn, ~p"/")) == ~p"/inbox"
    end

    test "reopens the remembered organization after a second step", %{
      conn: conn,
      user: user,
      second: second
    } do
      conn = open_then_log_out(conn, user, second)
      {secret, _codes} = totp_fixture(user)

      conn = log_in_with_password(conn, user)
      assert redirected_to(conn) == ~p"/users/log-in/second-step"

      conn =
        post(recycle(conn), ~p"/users/log-in/second-step", %{
          "second_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert get_session(conn, :current_organization_id) == second.id
      assert redirected_to(get(conn, ~p"/")) == ~p"/inbox"
    end

    test "a link into another organization reaches the picker, not the remembered one", %{
      conn: conn,
      user: user,
      first: first,
      second: second
    } do
      resource =
        Renga.TriageFixtures.resource_fixture(
          Accounts.scope_for_user(user, second.id),
          "server",
          "db-01"
        )

      path = ~p"/inventory/#{resource.id}"
      conn = open_then_log_out(conn, user, first)
      conn = get(conn, path)
      assert redirected_to(conn) == ~p"/users/log-in"

      {token, _hashed_token} = generate_user_magic_link_token(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == path
      assert redirected_to(get(conn, path)) == ~p"/organizations"
    end

    for method <- [:password, :magic_link] do
      test "a link to a page reopens the remembered organization (#{method})", %{
        conn: conn,
        user: user,
        second: second
      } do
        conn = conn |> open_then_log_out(user, second) |> get(~p"/inbox")
        conn = log_in(conn, user, unquote(method))

        assert redirected_to(conn) == ~p"/inbox"
        assert get_session(conn, :current_organization_id) == second.id
        assert html_response(get(conn, ~p"/inbox"), 200)
      end
    end

    for method <- [:password, :magic_link] do
      test "a link into the user's only organization opens there (#{method})", %{
        conn: conn,
        user: user,
        first: first,
        second: second
      } do
        resource =
          Renga.TriageFixtures.resource_fixture(
            Accounts.scope_for_user(user, first.id),
            "server",
            "web-01"
          )

        # The remembered organization is no longer the user's to open.
        conn = open_then_log_out(conn, user, second)
        disable_membership(user, second)

        path = ~p"/inventory/#{resource.id}?from=link"
        conn = get(conn, path)
        conn = log_in(conn, user, unquote(method))

        assert redirected_to(conn) == path
        assert html_response(get(conn, path), 200) =~ "web-01"
      end
    end

    test "a link to another tenant's record finds nothing in the user's only organization", %{
      conn: conn,
      user: user,
      second: second
    } do
      disable_membership(user, second)
      stranger = user_fixture()
      theirs = organization_fixture()
      organization_membership_fixture(stranger, theirs, %{role: "owner"})

      resource =
        Renga.TriageFixtures.resource_fixture(
          Accounts.scope_for_user(stranger, theirs.id),
          "server",
          "secret-01"
        )

      path = ~p"/inventory/#{resource.id}"
      conn = conn |> get(path) |> log_in(user, :magic_link)

      assert redirected_to(conn) == path
      assert_error_sent 404, fn -> get(conn, path) end
    end
  end

  defp log_in(conn, user, :password), do: log_in_with_password(conn, user)

  defp log_in(conn, user, :magic_link) do
    {token, _hashed_token} = generate_user_magic_link_token(user)
    post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})
  end

  defp disable_membership(user, organization) do
    membership = Accounts.get_membership_for_user(organization, user.id)
    {:ok, _} = Accounts.update_organization_membership(membership, %{status: "disabled"})
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  defp age_pending_sign_ins(user, minutes) do
    Renga.Repo.update_all(
      from(t in Accounts.UserToken, where: t.user_id == ^user.id and t.context == "second_step"),
      set: [inserted_at: DateTime.add(Renga.Time.utc_now_ms(), minutes, :minute)]
    )
  end
end
