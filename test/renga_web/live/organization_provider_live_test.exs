defmodule RengaWeb.OrganizationProviderLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationDomains
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.FakeOIDCProvider
  alias Renga.FakeTxtResolver

  defp member_conn(conn, role) do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Scope.for_membership(user, organization, membership)}
  end

  defp provider_fixture(scope, overrides \\ %{}) do
    {:ok, {provider, _}} =
      OrganizationProviders.create(
        scope,
        Map.merge(
          %{
            "id" => OrganizationProviders.new_id(),
            "issuer" => "https://login.example.com",
            "display_name" => "Example SSO",
            "client_id" => "renga",
            "client_secret" => "s3cret"
          },
          overrides
        )
      )

    provider
  end

  defp activate(%IdentityProvider{} = provider) do
    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Renga.Repo.update!()
  end

  test "other members are told who manages providers", %{conn: conn} do
    {_owner_conn, owner} = member_conn(build_conn(), "owner")
    provider_fixture(owner)

    {conn, _scope} = member_conn(conn, "admin")
    {:ok, view, html} = live(conn, ~p"/settings/identity-providers")

    assert has_element?(view, "#providers-owners-only")
    refute has_element?(view, "#provider-list")
    refute has_element?(view, "#new-provider")
    refute html =~ "Example SSO"
  end

  test "an owner adds a provider with the callback URL it shows", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    view |> element("#new-provider") |> render_click()
    callback = view |> element("#provider-callback") |> render()
    [_, id] = Regex.run(~r"/users/auth/(org-[a-z2-7]{10})/callback", callback)

    view
    |> form("#provider-form", %{
      "provider" => %{
        "display_name" => "Okta",
        "issuer" => "https://acme.okta.com",
        "client_id" => "renga",
        "client_secret" => "s3cret",
        "email_domains" => "acme.com, acme.io",
        "allow_sign_up" => "true"
      }
    })
    |> render_submit()

    assert render(view) =~ "Okta added. Test its sign-in to turn it on."
    assert has_element?(view, "#provider-#{id}-status", "Waiting for a test sign-in")
    assert has_element?(view, "#provider-#{id}-test")
    refute has_element?(view, "#provider-#{id}-toggle")

    provider = OrganizationProviders.get(scope, id)
    revision = IdentityProviders.pending_revision(provider)
    assert revision.email_domains == ["acme.com", "acme.io"]
    assert revision.allow_sign_up

    {:ok, _view, html} = live(conn, ~p"/activity")
    assert html =~ "Added the identity provider Okta, waiting for a test sign-in"
  end

  test "an http issuer is refused in the form", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    view |> element("#new-provider") |> render_click()

    html =
      view
      |> form("#provider-form", %{
        "provider" => %{
          "display_name" => "Okta",
          "issuer" => "http://acme.okta.com",
          "client_id" => "renga",
          "client_secret" => "sentinel-secret-1f2e"
        }
      })
      |> render_submit()

    assert html =~ "https"
    assert OrganizationProviders.list(scope) == []
    # The refused form doesn't send the secret back.
    refute html =~ "sentinel-secret-1f2e"
    assert has_element?(view, ~s|#provider-form input[name="provider[client_secret]"][value=""]|)
  end

  test "the client secret is filtered from logged event parameters" do
    filtered =
      Phoenix.Logger.filter_values(%{"provider" => %{"client_secret" => "sentinel-secret-1f2e"}})

    assert filtered == %{"provider" => %{"client_secret" => "[FILTERED]"}}
  end

  test "editing proposes new settings that wait for a test", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")
    provider = scope |> provider_fixture() |> activate()
    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    assert has_element?(view, "#provider-#{provider.id}-status", "On")
    view |> element("#provider-#{provider.id}-edit") |> render_click()

    view
    |> form("#provider-form", %{
      "provider" => %{"display_name" => "Acme SSO", "client_id" => "renga-2"}
    })
    |> render_submit()

    assert has_element?(
             view,
             "#provider-#{provider.id}-status",
             "new settings waiting for a test sign-in"
           )

    provider = OrganizationProviders.get(scope, provider.id)
    assert provider.display_name == "Acme SSO"
    assert IdentityProviders.pending_revision(provider).client_id == "renga-2"

    assert {:ok, "s3cret"} =
             IdentityProviders.client_secret(IdentityProviders.pending_revision(provider))

    view |> element("#provider-#{provider.id}-discard") |> render_click()
    assert has_element?(view, "#provider-#{provider.id}-status", "On")
  end

  test "an owner turns a provider off and on, and removes it", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")
    provider = scope |> provider_fixture() |> activate()
    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    view |> element("#provider-#{provider.id}-toggle") |> render_click()
    assert has_element?(view, "#provider-#{provider.id}-status", "Off")
    view |> element("#provider-#{provider.id}-toggle") |> render_click()
    assert has_element?(view, "#provider-#{provider.id}-status", "On")

    render_click(view, "remove", %{id: provider.id})
    refute has_element?(view, "#provider-#{provider.id}")
    assert OrganizationProviders.list(scope) == []
  end

  test "lists only the organization's own providers", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")
    provider_fixture(scope, %{"display_name" => "Ours"})
    {_other_conn, other} = member_conn(build_conn(), "owner")
    theirs = provider_fixture(other, %{"display_name" => "Theirs"})
    deployment = identity_provider_fixture(FakeOIDCProvider.new())

    {:ok, view, html} = live(conn, ~p"/settings/identity-providers")

    assert html =~ "Ours"
    refute html =~ "Theirs"
    refute has_element?(view, "#provider-#{deployment.id}")

    render_click(view, "remove", %{id: theirs.id})
    assert IdentityProviders.get_any(theirs.id)
  end

  test "a test sign-in activates the provider and returns to this page", %{conn: conn} do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)

    {conn, scope} = member_conn(conn, "owner")

    provider =
      provider_fixture(scope, %{"issuer" => fake.issuer, "client_id" => fake.client_id})

    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    assert {:error, {:redirect, %{to: "/users/providers/test/" <> token}}} =
             view |> element("#provider-#{provider.id}-test") |> render_click()

    conn = get(conn, ~p"/users/providers/test/#{token}")
    params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), %{"sub" => "owner-1"})
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/settings/identity-providers"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "now uses revision 1"
    assert IdentityProviders.usable?(OrganizationProviders.get(scope, provider.id))
  end

  test "only the owner who created a test, still an owner, can finish it", %{conn: conn} do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    {owner_conn, scope} = member_conn(conn, "owner")

    provider =
      provider_fixture(scope, %{"issuer" => fake.issuer, "client_id" => fake.client_id})

    new_test = fn ->
      {:ok, {token, _test}} = OrganizationProviders.create_test(scope, provider)
      token
    end

    # A signed-out browser, or someone else, can't open the link or spend it.
    for browser <- [build_conn(), elem(member_conn(build_conn(), "owner"), 0)] do
      token = new_test.()
      conn = get(browser, ~p"/users/providers/test/#{token}")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Only the owner who created"
    end

    # An owner who started the test and then lost the role activates nothing.
    token = new_test.()
    conn = get(owner_conn, ~p"/users/providers/test/#{token}")
    params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), %{"sub" => "owner-1"})

    Renga.Repo.update_all(
      from(m in Renga.Accounts.OrganizationMembership, where: m.id == ^scope.membership_id),
      set: [role: "member"]
    )

    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Only the owner who created"
    refute IdentityProviders.usable?(OrganizationProviders.get(scope, provider.id))
  end

  test "a test sign-in that can't start returns to this page", %{conn: conn} do
    {conn, scope} = member_conn(conn, "owner")

    # A loopback issuer fails the destination policy before any request.
    provider = provider_fixture(scope, %{"issuer" => "https://127.0.0.1"})
    {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

    assert {:error, {:redirect, %{to: "/users/providers/test/" <> token}}} =
             view |> element("#provider-#{provider.id}-test") |> render_click()

    conn = get(conn, ~p"/users/providers/test/#{token}")

    assert redirected_to(conn) == ~p"/settings/identity-providers"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "test sign-in didn't work"
    refute IdentityProviders.usable?(OrganizationProviders.get(scope, provider.id))
  end

  # Each module verifies its own domains: async tests verifying the same one
  # would wait on each other's uncommitted rows.
  describe "email domains" do
    test "an owner claims a domain, publishes its record, and verifies it", %{conn: conn} do
      {conn, scope} = member_conn(conn, "owner")
      {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

      assert has_element?(view, "#domain-list", "No email domains yet.")

      html =
        view
        |> form("#domain-form", domain: %{domain: "Settings.Acme.Example"})
        |> render_submit()

      assert html =~ "Publish the TXT record for settings.acme.example"

      [claim] = OrganizationDomains.list(scope)
      assert has_element?(view, "#domain-#{claim.id}-status", "Waiting for its DNS record")

      assert has_element?(
               view,
               "#domain-#{claim.id}-record",
               "_renga-verification.settings.acme.example"
             )

      assert has_element?(
               view,
               "#domain-#{claim.id}-record",
               OrganizationDomains.record_value(claim)
             )

      html = view |> element("#domain-#{claim.id}-verify") |> render_click()
      assert html =~ "couldn&#39;t find"

      FakeTxtResolver.put(OrganizationDomains.record_name(claim), [
        OrganizationDomains.record_value(claim)
      ])

      html = view |> element("#domain-#{claim.id}-verify") |> render_click()
      assert html =~ "settings.acme.example is verified"
      assert has_element?(view, "#domain-#{claim.id}-status", "Verified")
      refute has_element?(view, "#domain-#{claim.id}-record")

      view |> element("#domain-#{claim.id}-remove") |> render_click()
      assert OrganizationDomains.list(scope) == []
      assert has_element?(view, "#domain-list", "No email domains yet.")
    end

    test "a bad or repeated domain is refused in the form", %{conn: conn} do
      {conn, scope} = member_conn(conn, "owner")
      {:ok, _claim} = OrganizationDomains.add(scope, "settings.acme.example")
      {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

      html = view |> form("#domain-form", domain: %{domain: "not a domain"}) |> render_submit()
      assert html =~ "must be a domain such as example.com"

      html =
        view
        |> form("#domain-form", domain: %{domain: "settings.acme.example"})
        |> render_submit()

      assert html =~ "is already listed"
      assert length(OrganizationDomains.list(scope)) == 1
    end

    test "only owners see the domains", %{conn: conn} do
      {conn, _scope} = member_conn(conn, "admin")
      {:ok, view, _html} = live(conn, ~p"/settings/identity-providers")

      refute has_element?(view, "#organization-domains")
    end
  end
end
