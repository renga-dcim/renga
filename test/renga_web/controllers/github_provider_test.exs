defmodule RengaWeb.GitHubProviderTest do
  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OIDC
  alias Renga.FakeGitHub

  @user %{"id" => 583_231, "login" => "octocat"}
  @emails [
    %{"email" => "old@example.com", "primary" => false, "verified" => true},
    %{"email" => "octocat@example.com", "primary" => true, "verified" => true}
  ]

  setup do
    FakeGitHub.stub()

    {:ok, {provider, _revision}} =
      IdentityProviders.create(
        %{
          "id" => "github",
          "kind" => "github",
          "display_name" => "GitHub",
          "icon" => "github",
          "client_id" => "github-client",
          "client_secret" => "client-secret"
        },
        {:operator, "test"}
      )

    provider =
      provider
      |> Ecto.Changeset.change(active_revision: 1, pending_revision: nil)
      |> Renga.Repo.update!()

    %{provider: provider}
  end

  defp start(conn) do
    conn = get(conn, ~p"/users/log-in/provider/github")
    {conn, redirected_to(conn, 302)}
  end

  defp linked_user(conn) do
    user = set_password(user_fixture())
    conn = log_in_user(conn, user)

    :ok =
      Accounts.recheck_with_password(user, get_session(conn, :user_token), valid_user_password())

    conn = post(conn, ~p"/users/settings/identities", %{"provider" => "github"})
    params = FakeGitHub.authorize(redirected_to(conn, 302), @user, @emails)
    conn = get(recycle(conn), ~p"/users/auth/github/callback", params)
    {conn, user}
  end

  test "the authorization URL uses PKCE and asks only to read the account", %{conn: conn} do
    {_conn, url} = start(conn)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://github.com/login/oauth/authorize"
    assert query["client_id"] == "github-client"
    assert query["scope"] == "read:user user:email"
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"]
    assert query["state"]
  end

  test "a first sign-in never creates an account", %{conn: conn} do
    {conn, url} = start(conn)
    params = FakeGitHub.authorize(url, @user, @emails)
    conn = get(recycle(conn), ~p"/users/auth/github/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "doesn't create new accounts"
    refute get_session(conn, :user_token)
    refute Accounts.get_user_by_email("octocat@example.com")
  end

  test "a first sign-in matching an account's email asks to link it there", %{conn: conn} do
    user_fixture(%{email: "octocat@example.com"})

    {conn, url} = start(conn)
    params = FakeGitHub.authorize(url, @user, @emails)
    conn = get(recycle(conn), ~p"/users/auth/github/callback", params)

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Log in to it another way"
    refute get_session(conn, :user_token)
  end

  test "links to a signed-in account by the numeric user ID", %{conn: conn} do
    {conn, user} = linked_user(conn)

    assert redirected_to(conn) == ~p"/users/settings"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "GitHub is connected"

    assert [identity] = Accounts.list_user_identities(user)
    assert identity.subject == "583231"
    assert identity.email == "octocat@example.com"
  end

  test "a linked account signs in, even after renaming itself", %{conn: conn} do
    {_conn, user} = linked_user(conn)

    {conn, url} = start(build_conn())
    params = FakeGitHub.authorize(url, %{@user | "login" => "renamed"}, @emails)
    conn = get(recycle(conn), ~p"/users/auth/github/callback", params)

    {signed_in, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert signed_in.id == user.id
  end

  test "a refused code exchange signs nobody in", %{conn: conn} do
    {_conn, user} = linked_user(conn)

    {conn, url} = start(build_conn())
    params = FakeGitHub.authorize(url, @user, @emails)
    conn = get(recycle(conn), ~p"/users/auth/github/callback", %{params | "code" => "forged"})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't work"
    refute get_session(conn, :user_token)
    assert [_identity] = Accounts.list_user_identities(user)
  end

  test "the email domain allowlist needs a verified primary email", %{
    conn: conn,
    provider: provider
  } do
    {:ok, {provider, _}} =
      IdentityProviders.propose_revision(provider, %{"email_domains" => ["example.com"]}, {
        :operator,
        "test"
      })

    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Renga.Repo.update!()

    user = set_password(user_fixture())
    conn = log_in_user(conn, user)

    :ok =
      Accounts.recheck_with_password(user, get_session(conn, :user_token), valid_user_password())

    for emails <- [
          :forbidden,
          [%{"email" => "octocat@example.com", "primary" => true, "verified" => false}],
          [%{"email" => "octocat@example.com", "primary" => false, "verified" => true}]
        ] do
      conn = post(conn, ~p"/users/settings/identities", %{"provider" => "github"})
      params = FakeGitHub.authorize(redirected_to(conn, 302), @user, emails)
      conn = get(recycle(conn), ~p"/users/auth/github/callback", params)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't open to your email"
    end

    assert Accounts.list_user_identities(user) == []
  end

  test "a GitHub identity never passes the account re-check", %{conn: conn, provider: provider} do
    {_conn, user} = linked_user(conn)
    user = Renga.Repo.update!(Ecto.Changeset.change(user, hashed_password: nil))

    assert Accounts.recheck_methods(user) == []

    assert {:error, :unsupported} =
             OIDC.start(
               provider,
               "http://localhost/cb",
               {:recheck, user.id, Ecto.UUID.generate()}
             )
  end

  test "a test sign-in activates a GitHub provider's pending revision", %{provider: provider} do
    {:ok, {provider, _}} =
      IdentityProviders.propose_revision(provider, %{"client_id" => "new-client"}, {
        :operator,
        "test"
      })

    {:ok, {token, _test}} = IdentityProviders.create_test(provider, {:operator, "test"})

    conn = get(build_conn(), ~p"/users/providers/test/#{token}")
    url = redirected_to(conn, 302)
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "new-client"

    params = FakeGitHub.authorize(url, @user, @emails)
    conn = get(build_conn(), ~p"/users/auth/github/callback", params)

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "now uses revision 2"
    refute get_session(conn, :user_token)
    assert IdentityProviders.get("github").active_revision == 2
  end
end
