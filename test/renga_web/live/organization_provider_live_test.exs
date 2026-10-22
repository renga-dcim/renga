defmodule RengaWeb.OrganizationProviderLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.FakeOIDCProvider

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
          "client_secret" => "s3cret"
        }
      })
      |> render_submit()

    assert html =~ "https"
    assert OrganizationProviders.list(scope) == []
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

    conn = get(recycle(conn), ~p"/users/providers/test/#{token}")
    params = FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), %{"sub" => "owner-1"})
    conn = get(recycle(conn), ~p"/users/auth/#{provider.id}/callback", params)

    assert redirected_to(conn) == ~p"/settings/identity-providers"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "now uses revision 1"
    assert IdentityProviders.usable?(OrganizationProviders.get(scope, provider.id))
  end
end
