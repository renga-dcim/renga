defmodule Renga.InventoryTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Source

  describe "sources" do
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

      %{
        scope: Accounts.scope_for(organization),
        other_scope: Accounts.scope_for(other_organization)
      }
    end

    test "create_source/2 creates an organization-scoped source", %{scope: scope} do
      assert {:ok, %Source{} = source} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent",
                 capabilities: ["host.inventory"],
                 metadata: %{"interval_seconds" => 60}
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(source.id)
      assert source.organization_id == scope.organization_id
      assert source.status == "active"
      assert source.capabilities == ["host.inventory"]
      assert source.metadata == %{"interval_seconds" => 60}
    end

    test "list_sources/1 is scoped by organization", %{scope: scope, other_scope: other_scope} do
      {:ok, source} =
        Inventory.create_source(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      {:ok, _other_source} =
        Inventory.create_source(other_scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert Inventory.list_sources(scope) == [source]
    end

    test "get_source!/2 enforces organization scope", %{scope: scope, other_scope: other_scope} do
      {:ok, source} =
        Inventory.create_source(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert Inventory.get_source!(scope, source.id).id == source.id

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.get_source!(other_scope, source.id)
      end
    end

    test "source names are unique per organization", %{scope: scope, other_scope: other_scope} do
      attrs = %{kind: "host_agent", name: "iad-1-host-agent"}

      assert {:ok, _source} = Inventory.create_source(scope, attrs)
      assert {:ok, _source} = Inventory.create_source(other_scope, attrs)

      assert {:error, changeset} = Inventory.create_source(scope, attrs)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "validates kind and status", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_source(scope, %{
                 kind: "unknown",
                 name: "bad-source",
                 status: "missing"
               })

      assert %{
               kind: ["is invalid"],
               status: ["is invalid"]
             } = errors_on(changeset)
    end

    test "validates capabilities", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "bad-source",
                 capabilities: ["host.inventory", "   "]
               })

      assert %{capabilities: ["must contain only non-empty strings"]} = errors_on(changeset)
    end

    test "programmatic organization id is not cast from attrs", %{scope: scope} do
      assert {:ok, source} =
               Inventory.create_source(scope, %{
                 organization_id: Ecto.UUID.generate(),
                 kind: "host_agent",
                 name: "iad-1-host-agent"
               })

      assert source.organization_id == scope.organization_id
    end

    test "create_source_with_token/2 returns plaintext token and stores only a hash", %{
      scope: scope
    } do
      assert {:ok, {%Source{} = source, token}} =
               Inventory.create_source_with_token(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent"
               })

      assert String.starts_with?(token, "renga_src_")
      assert is_binary(source.token_hash)
      refute source.token_hash == token

      assert {:ok, authed_source} = Inventory.authenticate_source_token(token)
      assert authed_source.id == source.id
      assert authed_source.organization_id == scope.organization_id
    end

    test "regular source changes cannot set token_hash", %{scope: scope} do
      assert {:ok, source} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent",
                 token_hash: "caller-controlled"
               })

      assert source.token_hash == nil
    end

    test "rotate_source_token/2 replaces the token hash and invalidates old token", %{
      scope: scope
    } do
      {:ok, {source, old_token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert {:ok, {rotated_source, new_token}} = Inventory.rotate_source_token(scope, source.id)

      assert String.starts_with?(new_token, "renga_src_")
      refute new_token == old_token
      refute rotated_source.token_hash == source.token_hash
      assert rotated_source.status == "active"
      assert Inventory.authenticate_source_token(old_token) == :error
      assert {:ok, authed_source} = Inventory.authenticate_source_token(new_token)
      assert authed_source.id == source.id
    end

    test "rotate_source_token/2 is organization-scoped", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, {source, _token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.rotate_source_token(other_scope, source.id)
      end
    end

    test "revoke_source_token/2 removes token auth and marks source revoked", %{scope: scope} do
      {:ok, {source, token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert {:ok, revoked_source} = Inventory.revoke_source_token(scope, source.id)

      assert revoked_source.status == "revoked"
      assert revoked_source.token_hash == nil
      assert Inventory.authenticate_source_token(token) == :error
    end

    test "authenticate_source_token/1 rejects malformed tokens" do
      assert Inventory.authenticate_source_token("not-a-source-token") == :error
      assert Inventory.authenticate_source_token(nil) == :error
    end
  end
end
