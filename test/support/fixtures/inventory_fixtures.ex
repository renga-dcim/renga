defmodule Renga.InventoryFixtures do
  @moduledoc """
  Test helpers for organization-scoped inventory UI setup.
  """

  alias Renga.Accounts

  def organization_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "Acme Operations",
        slug: "acme-operations-#{suffix}"
      })

    {:ok, organization} = Accounts.create_organization(attrs)
    organization
  end

  def organization_membership_fixture(user, organization, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{user_id: user.id})
    {:ok, membership} = Accounts.create_organization_membership(organization, attrs)
    membership
  end
end
