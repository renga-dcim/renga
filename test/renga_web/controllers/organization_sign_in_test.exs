defmodule RengaWeb.OrganizationSignInTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Accounts.OrganizationDomains
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.Accounts.UserIdentity
  alias Renga.FakeOIDCProvider
  alias Renga.FakeTxtResolver
  alias Renga.Members
  alias Renga.Repo

  setup do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)

    organization = organization_fixture(%{name: "Acme Corp"})
    owner = user_fixture()
    membership = organization_membership_fixture(owner, organization, %{role: "owner"})
    scope = Scope.for_membership(owner, organization, membership)

    %{fake: fake, organization: organization, owner: scope, provider: provider(scope, fake)}
  end

  defp provider(scope, fake, overrides \\ %{}) do
    {:ok, {provider, _}} =
      OrganizationProviders.create(
        scope,
        Map.merge(
          %{
            "id" => OrganizationProviders.new_id(),
            "issuer" => fake.issuer,
            "display_name" => "Acme SSO",
            "client_id" => fake.client_id,
            "client_secret" => "client-secret",
            "allow_sign_up" => true
          },
          overrides
        )
      )

    # Activation is a test sign-in; these tests start from an active one.
    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Repo.update!()
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{"sub" => "acme-1", "email" => "sam@acme.example", "email_verified" => true},
      overrides
    )
  end

  defp sign_in(conn, fake, provider, claims) do
    conn = get(conn, ~p"/users/log-in/provider/#{provider.id}")
    params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), claims)
    get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)
  end

  defp session_user(conn) do
    {user, _inserted_at} =
      conn |> get_session(:user_token) |> Accounts.get_user_by_session_token()

    user
  end

  describe "the organization's sign-in link" do
    test "offers its providers first", %{
      conn: conn,
      organization: organization,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/users/log-in?organization=#{organization.slug}")

      assert has_element?(view, "#organization_provider_options", "Acme Corp")
      assert has_element?(view, "#provider-#{provider.id}", "Log in with Acme SSO")
    end

    test "the usual page never lists an organization's providers", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      refute has_element?(view, "#organization_provider_options")
      refute has_element?(view, "#provider-#{provider.id}")
    end

    test "an unknown organization, or one with no usable provider, shows the usual page", %{
      conn: conn,
      organization: organization,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/users/log-in?organization=nobody-here")
      refute has_element?(view, "#organization_provider_options")

      provider |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/users/log-in?organization=#{organization.slug}")
      refute has_element?(view, "#organization_provider_options")
    end
  end

  describe "an email at a verified domain" do
    # Each module verifies its own domains: async tests verifying the same
    # one would wait on each other's uncommitted rows.
    setup %{owner: owner} do
      {:ok, claim} = OrganizationDomains.add(owner, "sso.acme.example")
      %{claim: claim}
    end

    defp verify(owner, claim) do
      FakeTxtResolver.put(OrganizationDomains.record_name(claim), [
        OrganizationDomains.record_value(claim)
      ])

      {:ok, claim} = OrganizationDomains.verify(owner, claim)
      claim
    end

    test "leads from the usual page to the organization's sign-in", %{
      conn: conn,
      organization: organization,
      owner: owner,
      claim: claim,
      provider: provider
    } do
      verify(owner, claim)
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#organization_email_form", organization: %{email: "Sam@SSO.Acme.Example"})
               |> render_submit()

      assert to == ~p"/users/log-in?#{[organization: organization.slug]}"

      {:ok, view, _html} = live(conn, to)
      assert has_element?(view, "#provider-#{provider.id}", "Log in with Acme SSO")
      refute has_element?(view, "#organization_email_form")
    end

    test "stays on the page for any other address", %{conn: conn, owner: owner, claim: claim} do
      verify(owner, claim)
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      html =
        view
        |> form("#organization_email_form", organization: %{email: "sam@eu.sso.acme.example"})
        |> render_submit()

      assert html =~ "No organization signs in with that address."
      assert has_element?(view, "#login_form_magic")
    end

    test "an unverified domain routes nobody, and the page doesn't ask", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      refute has_element?(view, "#organization_email_form")
      refute OrganizationDomains.organization_slug_for_email("sam@sso.acme.example")
    end
  end

  describe "signing up" do
    test "creates an account with no global email and a session for the organization only", %{
      conn: conn,
      fake: fake,
      organization: organization,
      provider: provider
    } do
      conn = sign_in(conn, fake, provider, claims())

      assert redirected_to(conn) == ~p"/"
      user = session_user(conn)
      assert user.email == nil
      assert user.confirmed_at == nil
      assert user.session_organization_id == organization.id

      assert %UserIdentity{email: "sam@acme.example"} =
               Repo.get_by(UserIdentity, provider_id: provider.id, subject: "acme-1")

      # The asserted address reserves nothing: someone else can still
      # register it as their global email.
      assert %{email: "sam@acme.example"} = user_fixture(%{email: "sam@acme.example"})
    end

    test "the new account can find its way around", %{conn: conn, fake: fake, provider: provider} do
      conn = sign_in(conn, fake, provider, claims())

      {:ok, view, _html} = live(recycle(conn), ~p"/organizations")
      assert has_element?(view, "#scoped-session-organizations")

      {:ok, view, _html} = live(recycle(conn), ~p"/users/settings")
      assert has_element?(view, "#scoped_session_notice")
    end

    test "a returning person signs in to the same account", %{
      conn: conn,
      fake: fake,
      provider: provider
    } do
      first = conn |> sign_in(fake, provider, claims()) |> session_user()

      again =
        build_conn()
        |> sign_in(fake, provider, claims(%{"email" => "sam.new@acme.example"}))
        |> session_user()

      assert again.id == first.id

      assert %UserIdentity{email: "sam.new@acme.example"} =
               Repo.get_by(UserIdentity, provider_id: provider.id, subject: "acme-1")
    end

    test "never takes over an account with the same email", %{
      conn: conn,
      fake: fake,
      provider: provider
    } do
      existing = user_fixture(%{email: "sam@acme.example"})
      conn = sign_in(conn, fake, provider, claims())

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already uses that email"
      refute get_session(conn, :user_token)
      assert Accounts.list_user_identities(existing) == []
    end

    test "only when the organization allows it", %{conn: conn, fake: fake, organization: org} do
      owner = user_fixture()
      membership = organization_membership_fixture(owner, org, %{role: "owner"})

      closed =
        provider(Scope.for_membership(owner, org, membership), fake, %{"allow_sign_up" => false})

      conn = sign_in(conn, fake, closed, claims())

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end
  end

  test "a member signs in to their organization", %{
    conn: conn,
    fake: fake,
    organization: organization,
    provider: provider
  } do
    user = conn |> sign_in(fake, provider, claims()) |> session_user()
    organization_membership_fixture(user, organization)
    elsewhere = organization_fixture()
    organization_membership_fixture(user, elsewhere)

    conn = sign_in(build_conn(), fake, provider, claims())

    assert get_session(conn, :current_organization_id) == organization.id
    assert Accounts.scope_for_user(session_user(conn), elsewhere.id).organization_id == nil

    # Inside the organization, the account is named by the address its
    # provider asserts.
    {:ok, _view, html} = live(recycle(conn), ~p"/inbox")
    assert html =~ "sam@acme.example"
  end

  describe "joining by invitation" do
    defp invite(scope, email) do
      {:ok, _invitation} =
        Members.invite(
          scope,
          %{"email" => email, "role" => "member"},
          &"https://renga.test/invitations/#{&1}"
        )

      assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
      [_, token] = Regex.run(~r{/invitations/(\S+)}, body)
      token
    end

    test "with the address the organization's provider verified", %{
      conn: conn,
      fake: fake,
      organization: organization,
      owner: owner,
      provider: provider
    } do
      conn = sign_in(conn, fake, provider, claims())
      user = session_user(conn)

      assert {:ok, membership} =
               Members.accept_invitation(user, invite(owner, "Sam@Acme.example"))

      assert membership.organization_id == organization.id

      [member] = owner |> Members.list_members() |> Enum.filter(&(&1.user_id == user.id))
      assert Accounts.User.label(member.user) == "sam@acme.example"

      # Signed in again, the new member opens the organization, named there
      # by that address.
      conn = sign_in(build_conn(), fake, provider, claims())
      assert get_session(conn, :current_organization_id) == organization.id

      {:ok, _view, html} = live(recycle(conn), ~p"/inbox")
      assert html =~ "sam@acme.example"
      refute html =~ "Account without an email"
    end

    test "not with an address the provider didn't verify", %{
      conn: conn,
      fake: fake,
      owner: owner,
      provider: provider
    } do
      user = conn |> sign_in(fake, provider, claims()) |> session_user()

      # A later sign-in asserts the address unverified.
      build_conn() |> sign_in(fake, provider, claims(%{"email_verified" => false}))

      assert {:error, :wrong_email} =
               Members.accept_invitation(user, invite(owner, "sam@acme.example"))
    end

    test "not with a verification the provider sent as a string", %{
      conn: conn,
      fake: fake,
      owner: owner,
      provider: provider
    } do
      user =
        conn |> sign_in(fake, provider, claims(%{"email_verified" => "true"})) |> session_user()

      assert {:error, :wrong_email} =
               Members.accept_invitation(user, invite(owner, "sam@acme.example"))
    end

    test "not another organization's invitation, even signed in another way", %{
      conn: conn,
      fake: fake,
      provider: provider
    } do
      user = conn |> sign_in(fake, provider, claims()) |> session_user()
      other = organization_fixture()
      other_owner = user_fixture()
      membership = organization_membership_fixture(other_owner, other, %{role: "owner"})
      token = invite(Scope.for_membership(other_owner, other, membership), "sam@acme.example")

      assert {:error, :scoped_session} = Members.accept_invitation(user, token)

      assert {:error, :wrong_email} =
               Members.accept_invitation(Repo.get!(Accounts.User, user.id), token)
    end
  end

  describe "setting up a login email" do
    setup %{conn: conn, fake: fake, provider: provider} do
      conn = sign_in(conn, fake, provider, claims())
      {:ok, view, _html} = live(recycle(conn), ~p"/users/settings")
      %{conn: recycle(conn), user: session_user(conn), view: view}
    end

    defp send_code(view, email) do
      view
      |> form("#email_initialization_form", email_initialization: %{email: email})
      |> render_submit()

      assert_received {:email, %{subject: "Your Renga confirmation code"} = sent}
      assert sent.to == [{"", email}]
      [code] = Regex.run(~r/[A-Z0-9]{5}-[A-Z0-9]{5}/, sent.text_body)
      code
    end

    test "lets the account add a password and then sign in without its organization", %{
      conn: conn,
      organization: organization,
      user: %{session_expires_at: deadline},
      view: view
    } do
      assert has_element?(view, "#scoped_session_notice", "set up a login email")
      refute has_element?(view, "#email_form")

      # Nothing account-wide works before the email is set up.
      password = %{
        "user" => %{
          "password" => valid_user_password(),
          "password_confirmation" => valid_user_password()
        }
      }

      assert view |> form("#password_form", password) |> render_submit() =~
               "Set up your login email first."

      code = send_code(view, "sam@personal.example")
      assert has_element?(view, "#email_initialization_code_form", "sam@personal.example")

      html =
        view
        |> form("#email_initialization_code_form", email_initialization: %{code: code})
        |> render_submit()

      assert html =~ "sam@personal.example is your login email"
      assert has_element?(view, "#email_form")
      refute has_element?(view, "#account-email-initialization")
      assert has_element?(view, "#scoped_session_notice", "Add a password or passkey now")

      # Reloading the page in the same browser keeps the offer.
      {:ok, reloaded, _html} = live(conn, ~p"/users/settings")
      assert has_element?(reloaded, "#scoped_session_notice", "Add a password or passkey now")

      form = form(view, "#password_form", password)
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"

      # This browser stays signed in through the organization's provider,
      # until the same deadline as before.
      assert session_user(conn).session_organization_id == organization.id
      assert %DateTime{} = deadline
      assert session_user(conn).session_expires_at == deadline

      {:ok, view, _html} = live(recycle(conn), ~p"/users/settings")

      assert has_element?(
               view,
               "#scoped_session_notice",
               "Sign in another way to change these settings"
             )

      # The new password signs in to the whole account.
      user =
        Accounts.get_user_by_email_and_password("sam@personal.example", valid_user_password())

      assert user.confirmed_at
      assert user.session_organization_id == nil
    end

    test "a wrong code leaves the account as it was", %{user: user, view: view} do
      send_code(view, "sam@personal.example")

      html =
        view
        |> form("#email_initialization_code_form", email_initialization: %{code: "WRONG-CODE0"})
        |> render_submit()

      assert html =~ "That code isn&#39;t right."
      assert Repo.get!(Accounts.User, user.id).email == nil
    end

    test "another account's address is refused once its code is entered", %{
      user: user,
      view: view
    } do
      other = user_fixture()
      code = send_code(view, other.email)

      html =
        view
        |> form("#email_initialization_code_form", email_initialization: %{code: code})
        |> render_submit()

      assert html =~ "belongs to another account"
      assert Repo.get!(Accounts.User, user.id).email == nil
    end

    test "the address can be changed before confirming", %{view: view} do
      send_code(view, "sam@old.example")

      view |> element("#email_initialization_restart") |> render_click()
      code = send_code(view, "sam@new.example")

      assert view
             |> form("#email_initialization_code_form", email_initialization: %{code: code})
             |> render_submit() =~ "sam@new.example is your login email"
    end
  end

  test "a disabled organization's provider signs nobody in", %{
    conn: conn,
    fake: fake,
    organization: organization,
    provider: provider
  } do
    conn = get(conn, ~p"/users/log-in/provider/#{provider.id}")
    params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), claims())
    {:ok, _} = Accounts.update_organization(organization, %{status: "disabled"})

    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :user_token)
  end
end
