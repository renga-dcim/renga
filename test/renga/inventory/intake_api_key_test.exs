defmodule Renga.Inventory.IntakeApiKeyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})

    %{scope: Accounts.scope_for_user(user, organization.id), membership: membership}
  end

  test "creates a prefixed key, stores only its hash, and reveals plaintext once", %{scope: scope} do
    assert {:ok, {%IntakeApiKey{} = key, token}} =
             Inventory.create_intake_api_key(scope, %{name: "Production fleet"})

    assert String.starts_with?(token, "renga_intake_")
    assert key.name == "Production fleet"
    assert key.status == "active"
    assert is_binary(key.token_hash)
    refute key.token_hash == token

    [listed_key] = Inventory.list_intake_api_keys(scope)
    assert listed_key.id == key.id
    refute Map.has_key?(Map.from_struct(listed_key), :token)

    assert {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)
    assert authenticated_key.id == key.id
    assert authenticated_key.organization.id == scope.organization_id
  end

  test "supports overlapping active keys and independent revocation", %{scope: scope} do
    {:ok, {first, first_token}} =
      Inventory.create_intake_api_key(scope, %{name: "Current fleet"})

    {:ok, {second, second_token}} =
      Inventory.create_intake_api_key(scope, %{name: "Replacement fleet"})

    assert {:ok, _key} = Inventory.authenticate_intake_api_key(first_token)
    assert {:ok, _key} = Inventory.authenticate_intake_api_key(second_token)

    assert {:ok, %IntakeApiKey{status: "revoked"}} =
             Inventory.revoke_intake_api_key(scope, first.id)

    assert Inventory.authenticate_intake_api_key(first_token) == :error
    assert {:ok, %{id: second_id}} = Inventory.authenticate_intake_api_key(second_token)
    assert second_id == second.id
  end

  test "lists and revokes keys only inside the selected organization", %{scope: scope} do
    other_user = user_fixture()
    other_organization = organization_fixture(%{name: "Other organization"})
    organization_membership_fixture(other_user, other_organization, %{role: "owner"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Private fleet"})

    assert Inventory.list_intake_api_keys(other_scope) == []
    assert {:error, :not_found} = Inventory.revoke_intake_api_key(other_scope, key.id)
    assert {:ok, _key} = Inventory.authenticate_intake_api_key(token)
  end

  test "rejects viewers and forged scopes", %{scope: scope} do
    viewer = user_fixture()
    organization = scope.organization
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    viewer_scope = Accounts.scope_for_user(viewer, organization.id)

    assert {:error, :forbidden} =
             Inventory.create_intake_api_key(viewer_scope, %{name: "Forged key"})

    assert Inventory.list_intake_api_keys(scope) == []
  end

  test "rechecks membership authorization inside each mutation", %{
    scope: scope,
    membership: membership
  } do
    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Existing key"})
    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "viewer"})

    assert {:error, :forbidden} =
             Inventory.create_intake_api_key(scope, %{name: "Unauthorized key"})

    assert {:error, :forbidden} = Inventory.revoke_intake_api_key(scope, key.id)
    assert {:ok, _key} = Inventory.authenticate_intake_api_key(token)
  end

  test "rejects keys for disabled organizations", %{scope: scope} do
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet key"})
    {:ok, _organization} = Accounts.update_organization(scope.organization, %{status: "disabled"})

    assert Inventory.authenticate_intake_api_key(token) == :error
    assert {:error, :forbidden} = Inventory.create_intake_api_key(scope, %{name: "Another key"})
  end

  test "validates names and rejects malformed tokens", %{scope: scope} do
    assert {:error, changeset} = Inventory.create_intake_api_key(scope, %{name: "  "})
    assert %{name: ["can't be blank"]} = errors_on(changeset)

    assert Inventory.authenticate_intake_api_key("not-an-intake-key") == :error
    assert Inventory.authenticate_intake_api_key(nil) == :error
  end

  test "token hashes are unique", %{scope: scope} do
    hash = :crypto.hash(:sha256, "same-token")

    Repo.insert!(%IntakeApiKey{
      organization_id: scope.organization_id,
      name: "First",
      token_hash: hash
    })

    assert {:error, changeset} =
             %IntakeApiKey{organization_id: scope.organization_id}
             |> IntakeApiKey.create_changeset(%{name: "Second"}, hash)
             |> Repo.insert()

    assert %{token_hash: ["has already been taken"]} = errors_on(changeset)
  end
end
