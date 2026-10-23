defmodule Renga.Accounts.OrganizationProvidersTest do
  use Renga.DataCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.Inventory.ChangeEvent

  defp scope(organization, role) do
    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: role})
    Scope.for_membership(user, organization, membership)
  end

  defp attrs(overrides \\ %{}) do
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
  end

  defp activate(%IdentityProvider{} = provider) do
    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Repo.update!()
  end

  setup do
    organization = organization_fixture()
    %{organization: organization, owner: scope(organization, "owner")}
  end

  describe "create/2" do
    test "an owner adds a pending provider to the organization", %{
      organization: organization,
      owner: owner
    } do
      assert {:ok, {provider, revision}} = OrganizationProviders.create(owner, attrs())

      assert provider.organization_id == organization.id
      assert provider.kind == "oidc"
      assert provider.pending_revision == 1
      refute provider.hidden
      assert revision.created_by == owner.user.email
      assert [%IdentityProvider{id: id}] = OrganizationProviders.list(owner)
      assert id == provider.id
      refute IdentityProviders.get(provider.id)
    end

    test "is always OpenID Connect over https", %{owner: owner} do
      assert {:ok, {provider, _}} =
               OrganizationProviders.create(owner, attrs(%{"kind" => "github"}))

      assert provider.kind == "oidc"

      assert {:error, %Ecto.Changeset{} = changeset} =
               OrganizationProviders.create(
                 owner,
                 attrs(%{"issuer" => "http://login.example.com"})
               )

      assert %{issuer: [_]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               OrganizationProviders.create(owner, attrs(%{"issuer" => "http://localhost:4000"}))

      assert %{issuer: ["must be an https URL"]} = errors_on(changeset)
    end

    test "cannot hide a provider from its organization", %{owner: owner} do
      assert {:ok, {provider, _}} =
               OrganizationProviders.create(owner, attrs(%{"hidden" => true}))

      refute provider.hidden
    end

    test "members without organization.manage are refused", %{organization: organization} do
      for role <- ["admin", "member"] do
        assert {:error, :forbidden} =
                 OrganizationProviders.create(scope(organization, role), attrs())
      end

      assert [] = IdentityProviders.list_for_organization(organization.id)
    end

    test "a scope without an organization is refused" do
      assert {:error, :forbidden} =
               OrganizationProviders.create(Scope.for_user(user_fixture()), attrs())
    end

    test "records the change in the organization's activity", %{
      organization: organization,
      owner: owner
    } do
      {:ok, {provider, _}} = OrganizationProviders.create(owner, attrs())

      assert [event] =
               Repo.all(
                 from e in ChangeEvent,
                   where:
                     e.organization_id == ^organization.id and
                       e.kind == "identity_provider_changed"
               )

      assert event.actor_user_id == owner.user.id
      assert event.field == provider.id
      assert %{"change" => "created", "name" => "Example SSO", "revision" => 1} = event.metadata
    end
  end

  describe "changes" do
    setup %{owner: owner} do
      {:ok, {provider, _}} = OrganizationProviders.create(owner, attrs())
      %{provider: provider}
    end

    test "an owner edits, tests, turns off, and removes a provider", %{
      owner: owner,
      provider: provider
    } do
      assert {:ok, provider} =
               OrganizationProviders.update_display(owner, provider, %{"display_name" => "Okta"})

      assert provider.display_name == "Okta"

      provider = activate(provider)

      assert {:ok, {provider, revision}} =
               OrganizationProviders.propose_revision(owner, provider, %{"client_id" => "new"})

      assert revision.number == 2
      assert {:ok, {token, test}} = OrganizationProviders.create_test(owner, provider)
      assert is_binary(token)
      assert test.revision == 2
      assert test.actor_user_id == owner.user.id

      assert {:ok, provider} = OrganizationProviders.discard_pending(owner, provider)
      assert provider.pending_revision == nil
      assert {:ok, %{enabled: false} = provider} = OrganizationProviders.disable(owner, provider)
      assert {:ok, %{enabled: true} = provider} = OrganizationProviders.enable(owner, provider)
      assert {:ok, _provider} = OrganizationProviders.remove(owner, provider)
      assert [] = OrganizationProviders.list(owner)

      changes =
        Repo.all(
          from e in ChangeEvent,
            where: e.field == ^provider.id,
            select: e.metadata["change"]
        )

      assert Enum.sort(changes) ==
               Enum.sort(~w(created updated revision_pending revision_discarded
                 disabled enabled removed))
    end

    test "members without organization.manage are refused", %{
      organization: organization,
      provider: provider
    } do
      admin = scope(organization, "admin")

      assert {:error, :forbidden} = OrganizationProviders.disable(admin, provider)
      assert {:error, :forbidden} = OrganizationProviders.remove(admin, provider)
      assert {:error, :forbidden} = OrganizationProviders.create_test(admin, provider)

      assert {:error, :forbidden} =
               OrganizationProviders.update_display(admin, provider, %{"display_name" => "X"})

      assert IdentityProviders.get_for_organization(organization.id, provider.id)
    end

    test "an owner cannot name another organization's provider", %{provider: provider} do
      other = scope(organization_fixture(), "owner")

      assert OrganizationProviders.get(other, provider.id) == nil
      assert {:error, :not_found} = OrganizationProviders.remove(other, provider)
      assert {:error, :not_found} = OrganizationProviders.create_test(other, provider)
      assert OrganizationProviders.get(other, provider.id) == nil
      refute IdentityProviders.get_any(provider.id).removed_at
    end

    test "an owner cannot change a deployment provider", %{owner: owner} do
      deployment = identity_provider_fixture(Renga.FakeOIDCProvider.new())

      assert {:error, :not_found} = OrganizationProviders.disable(owner, deployment)
      assert IdentityProviders.get(deployment.id).enabled
    end

    test "a member who stops being an owner is refused", %{
      organization: organization,
      provider: provider
    } do
      owner = scope(organization, "owner")

      Renga.Accounts.OrganizationMembership
      |> where(id: ^owner.membership_id)
      |> Repo.update_all(set: [role: "member"])

      assert {:error, :forbidden} = OrganizationProviders.remove(owner, provider)
    end
  end

  test "only owners manage providers", %{organization: organization, owner: owner} do
    assert OrganizationProviders.manage?(owner)
    refute OrganizationProviders.manage?(scope(organization, "admin"))

    # A custom role may carry organization.manage, which doesn't cover
    # identity providers (RFD 17).
    {:ok, role} =
      Renga.Roles.create_role(owner, %{
        "name" => "Settings",
        "permissions" => ["organization.manage"]
      })

    settings = scope(organization, "viewer")

    {:ok, _assignment} =
      Renga.Assignments.assign(owner, settings.membership_id, %{"role" => role.id})

    settings = Renga.Accounts.scope_for_user(settings.user, organization.id)

    assert Renga.Authorization.allowed?(settings, "organization.manage")
    refute OrganizationProviders.manage?(settings)
    assert {:error, :forbidden} = OrganizationProviders.create(settings, attrs())

    # The built-in owner role counts as an assignment too.
    assigned = scope(organization, "viewer")

    {:ok, _assignment} =
      Renga.Assignments.assign(owner, assigned.membership_id, %{"role" => "owner"})

    assigned = Renga.Accounts.scope_for_user(assigned.user, organization.id)

    assert OrganizationProviders.manage?(assigned)
    assert {:ok, _created} = OrganizationProviders.create(assigned, attrs())
  end

  test "new_id/0 is fresh and fits a provider ID" do
    id = OrganizationProviders.new_id()
    assert id =~ ~r/^org-[a-z2-7]{10}$/
    refute id == OrganizationProviders.new_id()
  end
end
