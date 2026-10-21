defmodule RengaWeb.UserSessionControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  alias Renga.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
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

    test "a link to a page leaves several organizations to the picker", %{
      conn: conn,
      user: user,
      first: first
    } do
      conn = conn |> open_then_log_out(user, first) |> get(~p"/inbox")
      conn = log_in_with_password(conn, user)

      assert redirected_to(conn) == ~p"/inbox"
      assert redirected_to(get(conn, ~p"/inbox")) == ~p"/organizations"
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
end
