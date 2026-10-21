defmodule RengaWeb.SignInPolicyTest do
  # Changes the application's sign-in settings.
  use RengaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.SignInPolicy
  alias Renga.FakeOIDCProvider

  setup do
    on_exit(fn ->
      Application.delete_env(:renga, :local_sign_in)
      Application.delete_env(:renga, :registration)
    end)

    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    %{fake: fake}
  end

  defp disable_local, do: Application.put_env(:renga, :local_sign_in, :disabled)

  describe "with local sign-in disabled" do
    setup %{fake: fake} do
      provider = identity_provider_fixture(fake)
      disable_local()
      %{provider: provider, user: set_password(user_fixture())}
    end

    test "the login page offers only providers", %{conn: conn, provider: provider} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#provider-#{provider.id}")
      refute html =~ "use your password"
      refute has_element?(lv, "#login_form_password")
      refute has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "#passkey_login_form")
    end

    test "passwords and emailed links no longer sign in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)

      # A link sent before the change no longer works either.
      {token, _} = generate_user_magic_link_token(user)
      conn = post(build_conn(), ~p"/users/log-in", %{"user" => %{"token" => token}})
      refute get_session(conn, :user_token)

      conn = post(build_conn(), ~p"/users/log-in/passkey", %{"passkey" => %{"response" => "{}"}})
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a sign-in the policy refuses as its session is issued signs nobody in", %{
      conn: conn,
      user: user
    } do
      # As when an override is revoked between the request's check and the
      # session being issued.
      conn =
        conn
        |> Map.replace!(:secret_key_base, RengaWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> fetch_flash()
        |> RengaWeb.UserAuth.log_in_user(user, %{}, "password")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't available"
      refute get_session(conn, :user_token)
    end

    test "the recovery override lets local credentials in again", %{conn: conn, user: user} do
      {:ok, _} = SignInPolicy.recover_local(30, "jane")

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end
  end

  test "closed registration sends people to the login page", %{conn: conn} do
    Application.put_env(:renga, :registration, :closed)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/register")
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")
    refute render(lv) =~ "Sign up"
  end

  describe "recovery mode" do
    setup do
      disable_local()
      :ok
    end

    test "browser routes show only the recovery page", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/users/log-in")) == ~p"/recovery"
      assert redirected_to(get(build_conn(), ~p"/")) == ~p"/recovery"
      assert response(post(build_conn(), ~p"/users/log-in", %{}), 503)

      {:ok, _lv, html} = live(build_conn(), ~p"/recovery")
      assert html =~ "Renga is in recovery mode"
      assert html =~ "bin/providers recover-local --actor NAME --minutes 60"
    end

    test "a signed-in session cannot reach protected pages", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert redirected_to(get(conn, ~p"/users/settings")) == ~p"/recovery"
    end

    test "a test link bootstraps the first provider", %{fake: fake} do
      {:ok, {provider, _}} =
        IdentityProviders.create(
          %{
            "id" => "first",
            "kind" => "oidc",
            "issuer" => fake.issuer,
            "display_name" => "First",
            "client_id" => fake.client_id,
            "client_secret" => "secret"
          },
          {:operator, "jane"}
        )

      {:ok, {token, _}} =
        IdentityProviders.create_test(provider, {:operator, "jane"})

      conn = get(build_conn(), ~p"/users/providers/test/#{token}")
      params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), %{"sub" => "op"})
      conn = get(build_conn(), ~p"/users/auth/first/callback", params)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute SignInPolicy.recovery_mode?()

      {:ok, lv, _html} = live(build_conn(), ~p"/users/log-in")
      assert has_element?(lv, "#provider-first")
    end

    test "the recovery page sends people to log in once recovery ends", %{conn: conn} do
      Application.delete_env(:renga, :local_sign_in)
      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/recovery")
    end
  end
end
