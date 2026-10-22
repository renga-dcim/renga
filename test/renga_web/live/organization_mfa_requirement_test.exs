defmodule RengaWeb.OrganizationMFARequirementTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.SessionMFA
  alias Renga.FakeAuthenticator
  alias Renga.SecuritySettings

  setup do
    organization = organization_fixture(%{name: "Strict Ops"})
    owner = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})

    {:ok, true} =
      SecuritySettings.put(
        Accounts.scope_for_user(owner, organization.id),
        :require_mfa,
        true
      )

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    %{organization: organization, member: member}
  end

  defp open(conn, user, organization, opts \\ []) do
    conn
    |> log_in_user(user, opts)
    |> put_session(:current_organization_id, organization.id)
  end

  test "a session without a second factor is asked for one", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    conn = open(conn, member, organization)

    assert {:error, {:redirect, %{to: "/organizations/confirm-mfa"}}} = live(conn, ~p"/inbox")
    assert redirected_to(get(conn, ~p"/")) == ~p"/organizations/confirm-mfa"

    {:ok, _lv, html} = live(conn, ~p"/organizations/confirm-mfa")
    assert html =~ "Strict Ops"
    assert html =~ "requires multi-factor authentication"
  end

  test "a session with Renga's second factor opens it", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    conn = open(conn, member, organization, mfa: SessionMFA.for_method(:totp))

    assert {:ok, _lv, _html} = live(conn, ~p"/inbox")

    assert {:error, {:redirect, %{to: "/inbox"}}} =
             live(conn, ~p"/organizations/confirm-mfa")
  end

  test "other organizations are unaffected", %{conn: conn, member: member} do
    relaxed = organization_fixture()
    organization_membership_fixture(member, relaxed, %{role: "member"})

    assert {:ok, _lv, _html} = live(open(conn, member, relaxed), ~p"/inbox")
  end

  test "selecting the organization leads to the confirmation", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    conn =
      conn
      |> log_in_user(member)
      |> post(~p"/organizations/select", %{"organization" => %{"id" => organization.id}})

    assert redirected_to(conn) == ~p"/organizations/confirm-mfa"
    assert get_session(conn, :current_organization_id) == organization.id
  end

  test "an authenticator code confirms it in place, without signing out", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    {secret, _codes} = totp_fixture(member)
    conn = open(conn, member, organization)
    token = get_session(conn, :user_token)

    {:ok, lv, _html} = live(conn, ~p"/organizations/confirm-mfa")
    assert has_element?(lv, "#confirm_mfa_form")
    refute has_element?(lv, "#confirm_mfa_enroll")

    wrong =
      post(conn, ~p"/organizations/confirm-mfa", %{
        "confirm_mfa" => %{"code" => wrong_totp_code(secret)}
      })

    assert redirected_to(wrong) == ~p"/organizations/confirm-mfa"
    assert Phoenix.Flash.get(wrong.assigns.flash, :error) =~ "didn't work"

    conn =
      post(conn, ~p"/organizations/confirm-mfa", %{
        "confirm_mfa" => %{"code" => NimbleTOTP.verification_code(secret)}
      })

    assert redirected_to(conn) == ~p"/inbox"
    assert get_session(conn, :user_token) == token
    assert {:ok, _lv, _html} = live(recycle(conn), ~p"/inbox")

    assert "second_factor_confirmed" in Enum.map(Accounts.list_security_events(member), & &1.kind)
  end

  test "a passkey confirms it in place", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    authenticator = FakeAuthenticator.new()

    {:ok, _passkey} =
      Passkeys.register(
        member,
        FakeAuthenticator.register(authenticator, Passkeys.registration_options(member))
      )

    conn = open(conn, member, organization)
    {:ok, lv, _html} = live(conn, ~p"/organizations/confirm-mfa")
    assert has_element?(lv, "#confirm_mfa_passkey_form")
    refute has_element?(lv, "#confirm_mfa_form")

    response =
      FakeAuthenticator.assert(authenticator, Accounts.passkey_options(member, "confirm_mfa"))

    conn =
      post(conn, ~p"/organizations/confirm-mfa", %{
        "confirm_mfa" => %{"passkey" => Jason.encode!(response)}
      })

    assert redirected_to(conn) == ~p"/inbox"
    assert {:ok, _lv, _html} = live(recycle(conn), ~p"/inbox")
  end

  test "a passkey challenge for another purpose cannot confirm it", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    authenticator = FakeAuthenticator.new()

    {:ok, _passkey} =
      Passkeys.register(
        member,
        FakeAuthenticator.register(authenticator, Passkeys.registration_options(member))
      )

    conn = open(conn, member, organization)

    response =
      FakeAuthenticator.assert(authenticator, Accounts.passkey_options(member, "recheck"))

    conn =
      post(conn, ~p"/organizations/confirm-mfa", %{
        "confirm_mfa" => %{"passkey" => Jason.encode!(response)}
      })

    assert redirected_to(conn) == ~p"/organizations/confirm-mfa"
  end

  test "a recovery code does not confirm it", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    {_secret, [code | _]} = totp_fixture(member)

    conn =
      open(conn, member, organization)
      |> post(~p"/organizations/confirm-mfa", %{"confirm_mfa" => %{"code" => code}})

    assert redirected_to(conn) == ~p"/organizations/confirm-mfa"
    assert Accounts.MFA.recovery_codes_left(member) == 10
  end

  test "a member with no factor is sent to add one", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    {:ok, lv, _html} = live(open(conn, member, organization), ~p"/organizations/confirm-mfa")

    assert has_element?(lv, "#confirm_mfa_enroll a[href='/users/settings']")
    refute has_element?(lv, "#confirm_mfa_form")
    refute has_element?(lv, "#confirm_mfa_passkey_form")
  end

  describe "provider sign-ins" do
    setup do
      fake = Renga.FakeOIDCProvider.new()
      %{provider: identity_provider_fixture(fake)}
    end

    test "count while the provider is marked, and stop at the next request once unmarked", %{
      conn: conn,
      member: member,
      organization: organization,
      provider: provider
    } do
      mfa = SessionMFA.for_provider(provider, %{})
      conn = open(conn, member, organization, mfa: mfa)
      assert {:error, {:redirect, _}} = live(conn, ~p"/inbox")

      {:ok, provider} =
        IdentityProviders.set_mfa_mark(provider, %{"enforces_mfa" => true}, {:operator, "op"})

      assert {:ok, _lv, _html} = live(conn, ~p"/inbox")

      {:ok, _provider} =
        IdentityProviders.set_mfa_mark(provider, %{"enforces_mfa" => false}, {:operator, "op"})

      assert {:error, {:redirect, %{to: "/organizations/confirm-mfa"}}} = live(conn, ~p"/inbox")
    end
  end
end
