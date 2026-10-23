defmodule Renga.ScimTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Roles
  alias Renga.Scim

  setup do
    organization = organization_fixture()

    %{
      organization: organization,
      owner: member_scope(organization, "owner"),
      admin: member_scope(organization, "admin"),
      provider: scim_provider_fixture()
    }
  end

  describe "create_connection/2" do
    test "an owner connects a deployment provider with sub by default", context do
      assert {:ok, connection} =
               Scim.create_connection(context.owner, %{
                 "provider_id" => context.provider.id,
                 "default_role" => "member"
               })

      assert connection.correlation_claim == "sub"
      assert connection.default_role == "member"
      assert Scim.enabled_connection?(context.organization.id)

      assert %ChangeEvent{actor_user_id: actor, metadata: metadata} =
               Repo.get_by!(ChangeEvent, kind: "scim_connection_created")

      assert actor == context.owner.user.id
      assert metadata["provider_id"] == context.provider.id
    end

    test "admins, and custom roles, cannot connect", context do
      assert {:error, :forbidden} =
               Scim.create_connection(context.admin, %{"provider_id" => context.provider.id})

      refute "scim.manage" in Renga.Authorization.custom_role_permissions()

      assert {:error, changeset} =
               Roles.create_role(context.owner, %{
                 "name" => "SCIM",
                 "permissions" => ["scim.manage"]
               })

      refute changeset.valid?
    end

    test "allows one enabled connection per organization", context do
      scim_connection_fixture(context.owner, %{"provider_id" => context.provider.id})

      assert {:error, changeset} =
               Scim.create_connection(context.owner, %{
                 "provider_id" => scim_provider_fixture().id
               })

      assert "already has a SCIM connection" in errors_on(changeset).organization_id
    end

    test "a replacement waits until the old connection is disabled", context do
      old = scim_connection_fixture(context.owner, %{"provider_id" => context.provider.id})
      assert {:ok, _disabled} = Scim.disable_connection(context.owner, old.id)
      refute Scim.enabled_connection?(context.organization.id)

      replacement = scim_connection_fixture(context.owner)
      assert {:error, :already_connected} = Scim.enable_connection(context.owner, old.id)

      assert Enum.map(Scim.list_connections(context.owner), & &1.id) == [replacement.id, old.id]
    end

    test "refuses GitHub, removed, disabled, and other organizations' providers", context do
      github =
        scim_provider_fixture(%{
          "kind" => "github",
          "issuer" => nil,
          "client_id" => "gh",
          "allow_sign_up" => false
        })

      disabled = scim_provider_fixture()
      {:ok, _} = IdentityProviders.disable(disabled, {:operator, "test"})
      removed = scim_provider_fixture()
      {:ok, _} = IdentityProviders.remove(removed, {:operator, "test"})

      other_org = scim_provider_fixture()

      other_org
      |> Ecto.Changeset.change(organization_id: organization_fixture().id)
      |> Repo.update!()

      for provider <- [github, disabled, removed, other_org] do
        assert {:error, changeset} =
                 Scim.create_connection(context.owner, %{"provider_id" => provider.id})

        assert "is not an available OpenID Connect provider" in errors_on(changeset).provider_id
      end

      assert Enum.map(Scim.eligible_providers(context.owner), & &1.id) == [context.provider.id]
    end

    test "accepts the organization's own provider", context do
      own =
        scim_provider_fixture()
        |> Ecto.Changeset.change(organization_id: context.organization.id)
        |> Repo.update!()

      assert {:ok, _connection} =
               Scim.create_connection(context.owner, %{"provider_id" => own.id})
    end

    test "permits only claims the provider declares", context do
      assert {:error, changeset} =
               Scim.create_connection(context.owner, %{
                 "provider_id" => context.provider.id,
                 "correlation_claim" => "email"
               })

      assert "is not a stable claim this provider declares" in errors_on(changeset).correlation_claim
    end

    test "rejects an unknown default role", context do
      assert {:error, changeset} =
               Scim.create_connection(context.owner, %{
                 "provider_id" => context.provider.id,
                 "default_role" => "root"
               })

      assert errors_on(changeset).default_role != []
    end
  end

  describe "update_default_role/3" do
    test "changes and clears the role with Activity", context do
      connection = scim_connection_fixture(context.owner)

      assert {:ok, %{default_role: "viewer"}} =
               Scim.update_default_role(context.owner, connection.id, "viewer")

      assert {:ok, %{default_role: nil}} =
               Scim.update_default_role(context.owner, connection.id, "")

      assert [cleared, set] =
               ChangeEvent
               |> where(kind: "scim_default_role_changed")
               |> order_by(desc: :occurred_at, desc: :inserted_at)
               |> Repo.all()
               |> Enum.sort_by(&is_nil(&1.new_value), :desc)

      assert cleared.old_value == %{"value" => "viewer"} and is_nil(cleared.new_value)
      assert set.new_value == %{"value" => "viewer"}
    end

    test "never reaches another organization's connection", context do
      other = member_scope(organization_fixture(), "owner")
      connection = scim_connection_fixture(other)

      assert {:error, :not_found} =
               Scim.update_default_role(context.owner, connection.id, "owner")
    end
  end

  describe "tokens" do
    test "authenticate only while the token, connection, and provider are live", context do
      connection = scim_connection_fixture(context.owner, %{"provider_id" => context.provider.id})
      {token, value} = scim_token_fixture(context.owner, connection)

      assert "renga_scim_" <> _ = value
      assert {:ok, authenticated, ^token} = Scim.authenticate(value)
      assert authenticated.id == connection.id
      assert authenticated.organization.id == context.organization.id

      assert :error = Scim.authenticate(value <> "x")
      assert :error = Scim.authenticate("renga_intake_" <> value)

      {:ok, _} = IdentityProviders.disable(context.provider, {:operator, "test"})
      assert :error = Scim.authenticate(value)
      {:ok, _} = IdentityProviders.enable(context.provider, {:operator, "test"})
      assert {:ok, _, _} = Scim.authenticate(value)

      {:ok, _} = Scim.disable_connection(context.owner, connection.id)
      assert :error = Scim.authenticate(value)
      {:ok, _} = Scim.enable_connection(context.owner, connection.id)
      assert {:ok, _, _} = Scim.authenticate(value)

      {:ok, _} = Scim.revoke_token(context.owner, token.id)
      assert :error = Scim.authenticate(value)
    end

    test "stop at an inactive organization", context do
      connection = scim_connection_fixture(context.owner)
      {_token, value} = scim_token_fixture(context.owner, connection)

      context.organization |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

      assert :error = Scim.authenticate(value)
    end

    test "allow two at a time for rotation", context do
      connection = scim_connection_fixture(context.owner)
      {first, first_value} = scim_token_fixture(context.owner, connection, "First")
      {_second, second_value} = scim_token_fixture(context.owner, connection, "Second")

      assert {:error, :too_many_tokens} =
               Scim.create_token(context.owner, connection.id, %{"name" => "Third"})

      {:ok, _} = Scim.revoke_token(context.owner, first.id)
      {_third, third_value} = scim_token_fixture(context.owner, connection, "Third")

      assert :error = Scim.authenticate(first_value)
      assert {:ok, _, _} = Scim.authenticate(second_value)
      assert {:ok, _, _} = Scim.authenticate(third_value)
    end

    test "keep only a hash and never put the value in Activity", context do
      connection = scim_connection_fixture(context.owner)
      {token, value} = scim_token_fixture(context.owner, connection)
      {:ok, _} = Scim.revoke_token(context.owner, token.id)

      assert Repo.reload!(token).token_hash == :crypto.hash(:sha256, value)
      refute inspect(Repo.reload!(token)) =~ value

      events = ChangeEvent |> where([e], like(e.kind, "scim_token_%")) |> Repo.all()

      assert Enum.map(events, & &1.kind) |> Enum.sort() ==
               ~w(scim_token_created scim_token_revoked)

      for event <- events do
        refute inspect(Map.from_struct(event)) =~ value
        assert event.metadata["token"] == "Okta"
        assert event.actor_user_id == context.owner.user.id
      end
    end

    test "only an owner of the connection's organization manages them", context do
      connection = scim_connection_fixture(context.owner)
      {token, _value} = scim_token_fixture(context.owner, connection)
      other = member_scope(organization_fixture(), "owner")

      assert {:error, :forbidden} =
               Scim.create_token(context.admin, connection.id, %{"name" => "x"})

      assert {:error, :not_found} = Scim.create_token(other, connection.id, %{"name" => "x"})
      assert {:error, :not_found} = Scim.revoke_token(other, token.id)
      assert {:error, :forbidden} = Scim.revoke_token(context.admin, token.id)
    end

    test "touch_token records use at most once a minute", context do
      connection = scim_connection_fixture(context.owner)
      {token, _value} = scim_token_fixture(context.owner, connection)

      :ok = Scim.touch_token(token)
      used = Repo.reload!(token).last_used_at
      assert used
      :ok = Scim.touch_token(token)
      assert Repo.reload!(token).last_used_at == used
    end
  end
end
