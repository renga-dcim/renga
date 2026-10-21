defmodule RengaWeb.UserProviderControllerTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.FakeOIDCProvider
  alias Renga.Repo

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

  test "opens the user's only organization", %{conn: conn, fake: fake, provider: provider} do
    {first, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    first = get(recycle(first), ~p"/users/auth/#{provider.id}/callback", params)
    {user, _} = Accounts.get_user_by_session_token(get_session(first, :user_token))

    organization = Renga.InventoryFixtures.organization_fixture()
    Renga.InventoryFixtures.organization_membership_fixture(user, organization, %{role: "owner"})

    {conn, url} = start(build_conn(), provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert get_session(conn, :current_organization_id) == organization.id
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

  test "a provider session ends at the provider's session lifetime", %{
    conn: conn,
    fake: fake
  } do
    provider = identity_provider_fixture(fake, %{"session_lifetime_seconds" => 300})
    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)
    token = get_session(conn, :user_token)

    deadline = Accounts.session_deadline(token)
    assert_in_delta DateTime.diff(deadline, DateTime.utc_now()), 300, 5

    # Renewing an old session keeps the deadline.
    eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

    Repo.update_all(where(Accounts.UserToken, token: ^token),
      set: [inserted_at: eight_days_ago]
    )

    conn = get(recycle(conn), ~p"/users/settings")
    assert html_response(conn, 200)
    assert Accounts.session_deadline(token) == deadline

    Repo.update_all(where(Accounts.UserToken, token: ^token),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    refute Accounts.get_user_by_session_token(token)
    conn = get(recycle(conn), ~p"/users/settings")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "a connected page leaves when its provider session ends", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user, nil, DateTime.add(DateTime.utc_now(), 1))
    conn = init_test_session(conn, user_token: token)

    {:ok, lv, _html} = live(conn, ~p"/users/settings")
    assert_redirect(lv, ~p"/users/log-in", 3_000)
  end

  test "an organization page with a provider session mounts and leaves at its end", %{
    conn: conn
  } do
    user = user_fixture()
    organization = Renga.InventoryFixtures.organization_fixture()
    Renga.InventoryFixtures.organization_membership_fixture(user, organization, %{role: "owner"})
    token = Accounts.generate_user_session_token(user, nil, DateTime.add(DateTime.utc_now(), 1))

    conn =
      init_test_session(conn, user_token: token, current_organization_id: organization.id)

    # Both the authentication and the organization hooks run here.
    {:ok, lv, _html} = live(conn, ~p"/places")
    assert_redirect(lv, ~p"/users/log-in", 3_000)
  end

  test "a failed provider sign-in still ends the browser's earlier session", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    user = user_fixture()
    conn = log_in_user(conn, user)
    old_token = get_session(conn, :user_token)

    {conn, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())

    {:ok, result} =
      Renga.Accounts.OIDC.finish(
        get_session(conn, :provider_attempt),
        params,
        "http://localhost:4002/users/auth/#{provider.id}/callback"
      )

    {:ok, _} = Accounts.IdentityProviders.disable(provider, {:operator, "test"})

    assert {:error, :inactive} = RengaWeb.UserAuth.log_in_user_with_provider(conn, result)
    refute Accounts.get_user_by_session_token(old_token)
  end

  # A sign-in finishing alongside this one can issue this browser a token
  # after the provider sign-in revoked the old one. The provider sign-in
  # deletes that token too, and announces it only once its transaction
  # has committed, so no page can mount on it in between.
  test "a token issued meanwhile is disconnected only after the sign-in commits", %{
    conn: conn,
    fake: fake,
    provider: provider
  } do
    user = user_fixture()
    browser_session_id = Ecto.UUID.generate()
    token = Accounts.generate_user_session_token(user, browser_session_id)
    conn = init_test_session(conn, user_token: token, browser_session_id: browser_session_id)

    {started, url} = start(conn, provider)
    params = FakeOIDCProvider.authorize(fake, url, claims())

    {:ok, result} =
      Renga.Accounts.OIDC.finish(
        get_session(started, :provider_attempt),
        params,
        "http://localhost:4002/users/auth/#{provider.id}/callback"
      )

    # The callback request, signed in as before.
    conn =
      build_conn()
      |> init_test_session(user_token: token, browser_session_id: browser_session_id)
      |> Plug.Conn.assign(:current_scope, Accounts.scope_for_user(user, nil))

    test_pid = self()
    handler = "token-issued-meanwhile-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:renga, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == test_pid, do: on_query(meta.query, user, browser_session_id)
      end,
      nil
    )

    try do
      assert {:ok, _conn, _return_to} = RengaWeb.UserAuth.log_in_user_with_provider(conn, result)
    after
      :telemetry.detach(handler)
    end

    {:inserted, meanwhile, _topic} = Process.get(:meanwhile)
    refute Process.get(:announced_early)
    refute Accounts.get_user_by_session_token(meanwhile)
    assert_received %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  # The first deletion of this browser's tokens is the revocation before the
  # sign-in transaction; a token issued right after it stands for one issued
  # by a concurrent sign-in. Any query after the second deletion and before
  # the commit runs inside the transaction, where its disconnect must not
  # have gone out yet.
  defp on_query(query, user, browser_session_id) do
    deletes_tokens? = query =~ ~r/^DELETE FROM "users_tokens"/
    if query == "commit" && Process.get(:inner_deleted), do: Process.put(:committed, true)

    case Process.get(:meanwhile) do
      nil when deletes_tokens? ->
        Process.put(:meanwhile, :inserting)
        meanwhile = Accounts.generate_user_session_token(user, browser_session_id)
        topic = "users_sessions:#{Base.url_encode64(meanwhile)}"
        RengaWeb.Endpoint.subscribe(topic)
        Process.put(:meanwhile, {:inserted, meanwhile, topic})

      {:inserted, _meanwhile, _topic} when deletes_tokens? ->
        Process.put(:inner_deleted, true)

      {:inserted, _meanwhile, topic} ->
        if Process.get(:inner_deleted) && !Process.get(:committed) do
          receive do
            %Phoenix.Socket.Broadcast{topic: ^topic} = message ->
              Process.put(:announced_early, true)
              send(self(), message)
          after
            0 -> :ok
          end
        end

      _other ->
        :ok
    end
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

  describe "test sign-in links" do
    setup %{fake: fake} do
      {:ok, {provider, _}} =
        Accounts.IdentityProviders.create(
          %{
            "id" => "new-idp-#{System.unique_integer([:positive])}",
            "kind" => "oidc",
            "issuer" => fake.issuer,
            "display_name" => "New SSO",
            "client_id" => fake.client_id,
            "client_secret" => "client-secret"
          },
          {:operator, "release"}
        )

      {:ok, {token, _}} = Accounts.IdentityProviders.create_test(provider, {:operator, "release"})
      %{new_provider: provider, token: token}
    end

    test "activate the tested revision from a browser with no Renga session", %{
      conn: conn,
      fake: fake,
      new_provider: provider,
      token: token
    } do
      conn = get(conn, ~p"/users/providers/test/#{token}")
      url = redirected_to(conn, 302)
      params = FakeOIDCProvider.authorize(fake, url, claims())

      conn = get(build_conn(), ~p"/users/auth/#{provider.id}/callback", params)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "now uses revision 1"
      refute get_session(conn, :user_token)
      assert Accounts.IdentityProviders.usable?(Accounts.IdentityProviders.get(provider.id))
      refute Accounts.get_user_by_email("sam@example.com")
    end

    test "leave a signed-in session as it was", %{
      conn: conn,
      fake: fake,
      new_provider: provider,
      token: token
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)
      session_token = get_session(conn, :user_token)

      conn = get(conn, ~p"/users/providers/test/#{token}")
      params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), claims())
      conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

      assert get_session(conn, :user_token) == session_token
      refute Accounts.authorized_account_change?(user, session_token, :change_email)
    end

    test "an expired or used link explains itself", %{conn: conn, token: token} do
      conn = get(conn, ~p"/users/providers/test/#{token}")
      assert redirected_to(conn, 302) =~ "/authorize"

      conn = get(build_conn(), ~p"/users/providers/test/#{token}")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was already used"
    end
  end
end
