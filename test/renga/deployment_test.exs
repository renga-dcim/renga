defmodule Renga.DeploymentTest do
  # Changes the deployment identifier, which is application environment.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Deployment
  alias Renga.Inventory

  setup do
    previous = Application.get_env(:renga, :deployment_id)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:renga, :deployment_id, previous),
        else: Application.delete_env(:renga, :deployment_id)
    end)
  end

  describe "valid_id?/1" do
    test "accepts short lowercase names" do
      for id <- ["eu1", "acme", "a", "us-east-2", String.duplicate("a", 16)] do
        assert Deployment.valid_id?(id), "expected #{inspect(id)} to be valid"
      end
    end

    test "rejects anything else" do
      for id <- ["", "EU1", "eu_1", "-eu1", "eu1-", "eu 1", String.duplicate("a", 17), nil] do
        refute Deployment.valid_id?(id), "expected #{inspect(id)} to be invalid"
      end
    end
  end

  describe "intake keys" do
    setup do
      user = user_fixture()
      organization = organization_fixture()
      organization_membership_fixture(user, organization, %{role: "admin"})
      %{scope: Accounts.scope_for_user(user, organization.id)}
    end

    test "carry the deployment identifier between the prefix and the secret", %{scope: scope} do
      Application.put_env(:renga, :deployment_id, "eu1")

      {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

      assert "renga_intake_eu1_" <> secret = token
      assert byte_size(Base.url_decode64!(secret, padding: false)) == 32
      assert key.deployment_id == "eu1"
      assert {:ok, %{id: id}} = Inventory.authenticate_intake_api_key(token)
      assert id == key.id
    end

    test "carry no identifier when the deployment has none", %{scope: scope} do
      Application.delete_env(:renga, :deployment_id)

      {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

      assert "renga_intake_" <> secret = token
      assert byte_size(Base.url_decode64!(secret, padding: false)) == 32
      assert key.deployment_id == nil
      assert {:ok, _key} = Inventory.authenticate_intake_api_key(token)
    end

    test "authenticate by hash alone, whatever the deployment's identifier is now", %{
      scope: scope
    } do
      Application.delete_env(:renga, :deployment_id)
      {:ok, {_key, without_id}} = Inventory.create_intake_api_key(scope, %{name: "Old"})
      Application.put_env(:renga, :deployment_id, "eu1")
      {:ok, {_key, with_id}} = Inventory.create_intake_api_key(scope, %{name: "New"})
      Application.put_env(:renga, :deployment_id, "us2")

      assert {:ok, _key} = Inventory.authenticate_intake_api_key(without_id)
      assert {:ok, _key} = Inventory.authenticate_intake_api_key(with_id)
    end

    test "never authenticate by identifier", %{scope: scope} do
      Application.put_env(:renga, :deployment_id, "eu1")
      {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
      "renga_intake_eu1_" <> secret = token

      # The right identifier with a wrong secret, and the right secret under a
      # different or missing identifier, are different keys.
      assert :error = Inventory.authenticate_intake_api_key("renga_intake_eu1_" <> "x" <> secret)
      assert :error = Inventory.authenticate_intake_api_key("renga_intake_us2_" <> secret)
      assert :error = Inventory.authenticate_intake_api_key("renga_intake_" <> secret)
    end
  end
end
