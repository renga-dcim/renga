defmodule Renga.AccountsTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Repo

  describe "organizations" do
    test "create_organization/1 creates an organization with a UUID primary key" do
      assert {:ok, %Organization{} = organization} =
               Accounts.create_organization(%{
                 name: "Acme Operations",
                 slug: "acme-ops"
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(organization.id)
      assert organization.status == "active"
      assert organization.settings == %{}
    end

    test "create_organization/1 validates slug format and uniqueness" do
      assert {:error, changeset} =
               Accounts.create_organization(%{
                 name: "Bad Slug",
                 slug: "Bad Slug"
               })

      assert %{slug: [_]} = errors_on(changeset)

      assert {:ok, _organization} =
               Accounts.create_organization(%{
                 name: "Acme Operations",
                 slug: "acme-ops"
               })

      assert {:error, changeset} =
               Accounts.create_organization(%{
                 name: "Acme Duplicate",
                 slug: "acme-ops"
               })

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "organization memberships" do
    setup do
      {:ok, organization} =
        Accounts.create_organization(%{
          name: "Acme Operations",
          slug: "acme-ops"
        })

      {:ok, other_organization} =
        Accounts.create_organization(%{
          name: "Beta Operations",
          slug: "beta-ops"
        })

      %{organization: organization, other_organization: other_organization}
    end

    test "create_organization_membership/2 stores UUID organization and user ids", %{
      organization: organization
    } do
      user_id = Ecto.UUID.generate()

      assert {:ok, %OrganizationMembership{} = membership} =
               Accounts.create_organization_membership(organization, %{
                 user_id: user_id,
                 role: "owner"
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(membership.id)
      assert membership.organization_id == organization.id
      assert membership.user_id == user_id
      assert membership.status == "active"
    end

    test "membership user id is required to be a UUID", %{organization: organization} do
      assert {:error, changeset} =
               Accounts.create_organization_membership(organization, %{
                 user_id: "not-a-uuid"
               })

      assert %{user_id: [_]} = errors_on(changeset)
    end

    test "list_organization_memberships/1 is scoped by organization", %{
      organization: organization,
      other_organization: other_organization
    } do
      {:ok, membership} =
        Accounts.create_organization_membership(organization, %{
          user_id: Ecto.UUID.generate(),
          role: "admin"
        })

      {:ok, _other_membership} =
        Accounts.create_organization_membership(other_organization, %{
          user_id: Ecto.UUID.generate(),
          role: "viewer"
        })

      scope = Accounts.scope_for(organization)

      assert Accounts.list_organization_memberships(scope) == [membership]
      assert Accounts.get_organization_membership!(scope, membership.id).id == membership.id
    end

    test "membership uniqueness is scoped by organization and user id", %{
      organization: organization,
      other_organization: other_organization
    } do
      user_id = Ecto.UUID.generate()

      assert {:ok, _membership} =
               Accounts.create_organization_membership(organization, %{user_id: user_id})

      assert {:ok, _membership} =
               Accounts.create_organization_membership(other_organization, %{user_id: user_id})

      assert {:error, changeset} =
               Accounts.create_organization_membership(organization, %{user_id: user_id})

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "programmatic organization id is not cast from attrs", %{organization: organization} do
      other_organization_id = Ecto.UUID.generate()

      assert {:ok, membership} =
               Accounts.create_organization_membership(organization, %{
                 organization_id: other_organization_id,
                 user_id: Ecto.UUID.generate()
               })

      assert membership.organization_id == organization.id
    end

    test "scope_for/2 carries organization and caller metadata", %{organization: organization} do
      user_id = Ecto.UUID.generate()
      membership_id = Ecto.UUID.generate()

      scope =
        Accounts.scope_for(organization, %{
          user_id: user_id,
          membership_id: membership_id,
          roles: ["owner"]
        })

      assert scope.organization == organization
      assert scope.organization_id == organization.id
      assert scope.user_id == user_id
      assert scope.membership_id == membership_id
      assert scope.roles == ["owner"]
    end
  end

  describe "database defaults" do
    test "organizations table defaults to UUID primary keys" do
      organization =
        %Organization{}
        |> Organization.changeset(%{name: "Gamma Operations", slug: "gamma-ops"})
        |> Repo.insert!()

      assert {:ok, _uuid} = Ecto.UUID.cast(organization.id)
    end
  end
end
