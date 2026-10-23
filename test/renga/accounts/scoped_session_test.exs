defmodule Renga.Accounts.ScopedSessionTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts
  alias Renga.Members

  setup do
    user = user_fixture() |> set_password()
    home = organization_fixture()
    other = organization_fixture()
    organization_membership_fixture(user, home)
    organization_membership_fixture(user, other)

    %{user: user, home: home, other: other}
  end

  # A session issued as an organization provider's sign-in will issue it.
  defp scoped_session(user, organization) do
    token =
      Accounts.generate_user_session_token(%{user | session_organization_id: organization.id})

    {session_user, _inserted_at} = Accounts.get_user_by_session_token(token)
    {token, session_user}
  end

  test "the session's user carries its organization", %{user: user, home: home} do
    {_token, session_user} = scoped_session(user, home)
    assert session_user.session_organization_id == home.id

    {unscoped, _inserted_at} =
      user |> Accounts.generate_user_session_token() |> Accounts.get_user_by_session_token()

    assert unscoped.session_organization_id == nil
  end

  test "opens only its organization", %{user: user, home: home, other: other} do
    {_token, session_user} = scoped_session(user, home)

    assert Accounts.scope_for_user(session_user, home.id).organization_id == home.id
    assert Accounts.scope_for_user(session_user, other.id).organization_id == nil
    assert Accounts.get_user_organization_membership(session_user, other.id) == nil

    assert [membership] = Accounts.list_user_organization_memberships(session_user)
    assert membership.organization_id == home.id
    assert Accounts.default_organization_id(session_user, other.id) == home.id

    # The same account, signed in another way, opens both.
    assert Accounts.scope_for_user(user, other.id).organization_id == other.id
    assert length(Accounts.list_user_organization_memberships(user)) == 2
  end

  test "a session issued from it keeps its scope", %{user: user, home: home} do
    {_token, session_user} = scoped_session(user, home)

    {reissued, _inserted_at} =
      session_user
      |> Accounts.generate_user_session_token()
      |> Accounts.get_user_by_session_token()

    assert reissued.session_organization_id == home.id
  end

  test "cannot create another organization", %{user: user, home: home} do
    {_token, session_user} = scoped_session(user, home)

    assert {:error, :scoped_session} =
             Accounts.create_organization_for_user(session_user, %{
               name: "Elsewhere",
               slug: "elsewhere-#{System.unique_integer([:positive])}"
             })
  end

  test "authorizes no account-wide change, even with the password", %{user: user, home: home} do
    {token, session_user} = scoped_session(user, home)

    assert {:error, :no_session} =
             Accounts.recheck_with_password(session_user, token, valid_user_password())

    for change <- [:change_email, :set_password, :add_factor, :link_identity, :unlink_identity] do
      refute Accounts.authorized_account_change?(session_user, token, change)
    end
  end

  describe "invitations" do
    defp invite(organization, user) do
      {:ok, _invitation} =
        Members.invite(
          member_scope(organization, "owner"),
          %{"email" => user.email, "role" => "member"},
          &"https://renga.test/invitations/#{&1}"
        )

      assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
      [_, token] = Regex.run(~r{/invitations/(\S+)}, body)
      token
    end

    test "only its own organization's", %{home: home} do
      user = user_fixture()
      third = organization_fixture()
      {_token, session_user} = scoped_session(user, home)

      assert {:error, :scoped_session} =
               Members.accept_invitation(session_user, invite(third, user))

      assert {:ok, _membership} = Members.accept_invitation(session_user, invite(home, user))
    end
  end

  test "ends when its organization is deleted", %{user: user} do
    organization = organization_fixture()
    {token, _session_user} = scoped_session(user, organization)
    Repo.delete!(organization)

    assert Accounts.get_user_by_session_token(token) == nil
  end
end
