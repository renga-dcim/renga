defmodule RengaWeb.UserProviderControllerTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.FakeOIDCProvider

  setup do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    %{fake: fake, provider: identity_provider_fixture(fake)}
  end

  defp start(conn, provider) do
    conn = get(conn, ~p"/users/log-in/provider/#{provider.id}")
    {conn, redirected_to(conn, 302)}
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{"sub" => "subject-1", "email" => "sam@example.com", "email_verified" => true},
      overrides
    )
  end

  test "the login page offers usable providers and hides hidden ones", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    hidden = identity_provider_fixture(fake, %{"display_name" => "Support", "hidden" => true})

    {:ok, lv, _html} = live(conn, ~p"/users/log-in")
    assert has_element?(lv, "#provider-#{provider.id}", "Log in with Company SSO")
    refute has_element?(lv, "#provider-#{hidden.id}")

    {:ok, lv, _html} = live(conn, ~p"/users/log-in?provider=#{hidden.id}")
    assert has_element?(lv, "#provider-#{hidden.id}", "Log in with Support")
  end

  test "signs in through the provider", %{conn: conn, fake: fake, provider: provider} do
    {conn, url} = start(conn, provider)
    assert String.starts_with?(url, fake.issuer <> "/authorize?")

    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/"
    assert token = get_session(conn, :user_token)
    refute get_session(conn, :provider_attempt)

    {user, _} = Accounts.get_user_by_session_token(token)
    assert user.email == "sam@example.com"

    assert [%{metadata: %{"method" => method}}] = Accounts.list_security_events(user)
    assert method == "provider:#{provider.id}"
  end

  test "an account with MFA signs in without a Renga second step", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)
    {user, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    totp_fixture(user)

    {conn, url} = start(build_conn(), provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
  end

  test "a callback without the attempt from this browser signs nobody in", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    {_conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())

    # Another browser, such as an attacker's, has no attempt in its session.
    conn = get(build_conn(), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :user_token)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't work"
  end

  test "the attempt is single use", %{conn: conn, fake: fake, provider: provider} do
    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)
    assert get_session(conn, :user_token)

    conn =
      conn
      |> recycle()
      |> get(~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "an attempt for one provider cannot complete another", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    other = identity_provider_fixture(fake)
    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())

    conn = get(recycle(conn), ~p"/users/auth/#{other.id}/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :user_token)
  end

  test "explains an email that another account uses", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    user_fixture(%{email: "sam@example.com"})
    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already uses that email"
    refute get_session(conn, :user_token)
  end

  test "an unknown or disabled provider sends people back to the login page", %{
    conn: conn,
    provider: provider
  } do
    conn = get(conn, ~p"/users/log-in/provider/nope")
    assert redirected_to(conn) == ~p"/users/log-in"

    {:ok, _} = Accounts.IdentityProviders.disable(provider, {:operator, "test"})
    conn = get(build_conn(), ~p"/users/log-in/provider/#{provider.id}")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
