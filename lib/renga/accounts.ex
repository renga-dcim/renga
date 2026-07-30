defmodule Renga.Accounts do
  @moduledoc """
  Accounts and organization tenancy boundaries.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Repo

  @doc """
  Builds a scope for context calls that must be organization-bound.
  """
  def scope_for(%Organization{} = organization, attrs \\ %{}) do
    Scope.new(organization, attrs)
  end

  def list_organizations do
    Repo.all(from organization in Organization, order_by: [asc: organization.name])
  end

  def get_organization!(id), do: Repo.get!(Organization, id)

  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def update_organization(%Organization{} = organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  def list_organization_memberships(%Organization{} = organization) do
    list_organization_memberships(scope_for(organization))
  end

  def list_organization_memberships(%Scope{organization_id: organization_id}) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> order_by([membership], asc: membership.user_id)
    |> Repo.all()
  end

  def get_organization_membership!(%Scope{organization_id: organization_id}, id) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  def get_membership_for_user(%Organization{} = organization, user_id) do
    get_membership_for_user(scope_for(organization), user_id)
  end

  def get_membership_for_user(%Scope{organization_id: organization_id}, user_id)
      when is_binary(user_id) do
    Repo.get_by(OrganizationMembership, organization_id: organization_id, user_id: user_id)
  end

  def create_organization_membership(%Organization{} = organization, attrs) do
    create_organization_membership(scope_for(organization), attrs)
  end

  def create_organization_membership(%Scope{organization_id: organization_id}, attrs) do
    %OrganizationMembership{organization_id: organization_id}
    |> OrganizationMembership.changeset(attrs)
    |> Repo.insert()
  end

  def update_organization_membership(%OrganizationMembership{} = membership, attrs) do
    membership
    |> OrganizationMembership.changeset(attrs)
    |> Repo.update()
  end
end
