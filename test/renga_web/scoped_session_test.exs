defmodule RengaWeb.ScopedSessionTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  setup %{conn: conn} do
    user = user_fixture() |> set_password()
    home = organization_fixture(%{name: "Home Org"})
    other = organization_fixture(%{name: "Other Org"})
    organization_membership_fixture(user, home)
    organization_membership_fixture(user, other)

    # As an organization provider's sign-in will issue it.
    conn =
      conn
      |> log_in_user(%{
        user
        | session_organization_id: home.id,
          session_expires_at: DateTime.add(Renga.Time.utc_now_ms(), 1, :hour)
      })
      |> put_session(:current_organization_id, home.id)

    %{conn: conn, user: user, home: home, other: other}
  end

  test "the organization picker offers only the session's organization", %{
    conn: conn,
    home: home,
    other: other
  } do
    {:ok, view, html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#select-organization-#{home.id}")
    refute has_element?(view, "#select-organization-#{other.id}")
    refute html =~ "Other Org"
    assert has_element?(view, "#scoped-session-organizations")
    refute has_element?(view, "#organization-form")
  end

  test "with no organization left, the picker doesn't offer to create one", %{conn: conn} do
    conn =
      log_in_user(conn, %{user_fixture() | session_organization_id: organization_fixture().id})

    {:ok, view, _html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#organizations-empty", "No organizations yet.")
    refute has_element?(view, "#organizations-empty", "Create the first one")
  end

  test "selecting another organization is refused", %{conn: conn, home: home, other: other} do
    conn = post(conn, ~p"/organizations/select", %{"organization" => %{"id" => other.id}})

    assert get_session(conn, :current_organization_id) == home.id
    assert redirected_to(conn) == ~p"/organizations"
  end

  test "a stale selection of another organization opens nothing", %{conn: conn, other: other} do
    conn = put_session(conn, :current_organization_id, other.id)

    assert {:error, {:redirect, %{to: "/organizations"}}} = live(conn, ~p"/inbox")
  end

  test "account settings explain and refuse sign-in changes", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert has_element?(view, "#scoped_session_notice")
    assert render_click(view, "remove_password", %{}) =~ "Sign in another way"
    refute has_element?(view, "#recheck")
    assert Renga.Repo.reload!(user).hashed_password
  end

  for invalidation <- [:expired, :revoked] do
    @invalidation invalidation

    test "#{invalidation} sessions stop an already-open organization mutation", %{
      conn: conn,
      user: user,
      home: home
    } do
      membership = Renga.Accounts.get_user_organization_membership(user, home.id)
      {:ok, _} = Renga.Accounts.update_organization_membership(membership, %{role: "owner"})
      {:ok, view, _} = live(conn, ~p"/settings/teams")
      invalidate_session(conn, @invalidation)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               render_submit(view, "save", %{"team" => %{"name" => "Must not be created"}})

      assert Renga.Teams.list_teams(Renga.Accounts.scope_for(home)) == []
      assert redirected_to(get(conn, ~p"/settings/teams")) == ~p"/users/log-in"
    end

    test "#{invalidation} sessions stop account-only and global events", %{conn: conn, user: user} do
      conn = delete_session(conn, :current_organization_id)
      {:ok, view, _} = live(conn, ~p"/users/settings")
      invalidate_session(conn, @invalidation)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = render_click(view, "cycle_theme")
      assert Renga.Repo.reload!(user).theme == user.theme
    end

    test "#{invalidation} sessions stop data delivery on an already-open page", %{
      conn: conn,
      home: home
    } do
      {:ok, view, _} = live(conn, ~p"/inventory")
      invalidate_session(conn, @invalidation)
      send(view.pid, {:inventory_changed, home.id})

      assert_redirect(view, ~p"/users/log-in")
    end

    test "#{invalidation} sessions stop navigation within an already-open page", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/inventory")
      invalidate_session(conn, @invalidation)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               render_patch(view, ~p"/inventory?kind=server")
    end
  end

  # Change the stored deadline after mounting: this leaves the original timer
  # pending and exercises enforcement independently of timer mailbox ordering.
  defp invalidate_session(conn, :expired) do
    token = get_session(conn, :user_token)
    record = Renga.Repo.get_by!(Renga.Accounts.UserToken, token: token, context: "session")

    record
    |> Ecto.Changeset.change(expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1, :second))
    |> Renga.Repo.update!()
  end

  defp invalidate_session(conn, :revoked),
    do: Renga.Accounts.delete_user_session_token(get_session(conn, :user_token))

  test "lifecycle changes immediately close only the affected organization's pages", %{
    conn: conn,
    user: user,
    home: home,
    other: other
  } do
    {:ok, home_view, _} = live(conn, ~p"/inventory")

    other_conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, other.id)

    {:ok, other_view, _} = live(other_conn, ~p"/inventory")

    # Lifecycle broadcasts are only wake-ups: a still-active organization
    # keeps working, and a committed suspension is re-read from the database.
    Phoenix.PubSub.broadcast(
      Renga.PubSub,
      "organization_lifecycle:#{home.id}",
      {:organization_lifecycle_changed, home.id}
    )

    assert has_element?(home_view, "#resource-list")
    {:ok, _} = Renga.Accounts.update_organization(home, %{status: "disabled"})

    Phoenix.PubSub.broadcast(
      Renga.PubSub,
      "organization_lifecycle:#{home.id}",
      {:organization_lifecycle_changed, home.id}
    )

    assert_redirect(home_view, ~p"/organizations")
    assert has_element?(other_view, "#resource-list")
    assert Renga.Accounts.get_user_by_session_token(get_session(conn, :user_token))
  end

  test "idle sockets discover revoked sessions, memberships and organizations without broadcasts",
       %{
         conn: conn,
         user: user,
         home: home,
         other: other
       } do
    account_conn = build_conn() |> log_in_user(user)
    {:ok, account_view, _} = live(account_conn, ~p"/users/settings")
    {:ok, membership_view, _} = live(conn, ~p"/inventory")

    organization_conn =
      build_conn() |> log_in_user(user) |> put_session(:current_organization_id, other.id)

    {:ok, organization_view, _} = live(organization_conn, ~p"/inventory")
    {:ok, valid_view, _} = live(log_in_user(build_conn(), user), ~p"/users/settings")

    # These low-level writes deliberately emit no wake-up notification.
    invalidate_session(account_conn, :revoked)
    membership = Renga.Accounts.get_user_organization_membership(user, home.id)
    {:ok, _} = Renga.Accounts.update_organization_membership(membership, %{status: "disabled"})
    {:ok, _} = Renga.Accounts.update_organization(other, %{status: "disabled"})

    assert_redirect(account_view, ~p"/users/log-in", 6_000)
    assert_redirect(membership_view, ~p"/organizations", 1_000)
    assert_redirect(organization_view, ~p"/organizations", 1_000)
    assert has_element?(valid_view, "#account")
  end
end
