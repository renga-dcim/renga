defmodule Renga.Accounts.OrganizationProvidersConcurrencyTest do
  @moduledoc """
  An owner's change to an organization provider takes the provider's locks
  before the organization's, the order a SCIM connection change takes them
  in (RFD 16), so the two never deadlock.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderEvent
  alias Renga.Accounts.IdentityProviderRevision
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.Accounts.User
  alias Renga.Repo
  alias Renga.Scim.Grants

  test "disabling a provider while a SCIM connection change holds it" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "owner"})
    owner = Scope.for_membership(user, organization, membership)

    {:ok, {provider, _revision}} =
      OrganizationProviders.create(owner, %{
        "id" => OrganizationProviders.new_id(),
        "issuer" => "https://login.example.com",
        "display_name" => "Example SSO",
        "client_id" => "renga",
        "client_secret" => "s3cret"
      })

    provider =
      provider
      |> Ecto.Changeset.change(active_revision: 1, pending_revision: nil, enabled: true)
      |> Repo.update!()

    parent = self()

    try do
      # What creating or re-enabling a SCIM connection does: hold the
      # provider, then lock the organization.
      connection_change =
        concurrent(fn ->
          Repo.transaction(fn ->
            Repo.one!(from p in IdentityProvider, where: p.id == ^provider.id, lock: "FOR SHARE")

            send(parent, {:holding_provider, self(), backend()})
            receive do: (:continue -> :ok)
            Grants.lock_organization(organization.id)
          end)
        end)

      assert_receive {:holding_provider, holder, holder_backend}, 1_000

      disable =
        concurrent(fn ->
          send(parent, {:disabling, backend()})
          OrganizationProviders.disable(owner, provider)
        end)

      assert_receive {:disabling, disable_backend}, 1_000
      assert blocked?(disable_backend, holder_backend)
      send(holder, :continue)

      assert {:ok, :ok} = Task.await(connection_change, 5_000)
      assert {:ok, %IdentityProvider{enabled: false}} = Task.await(disable, 5_000)
    after
      Repo.delete_all(where(IdentityProviderEvent, provider_id: ^provider.id))
      Repo.delete_all(where(IdentityProviderRevision, provider_id: ^provider.id))
      Repo.delete_all(where(IdentityProvider, id: ^provider.id))
      Repo.delete!(organization)
      Repo.delete_all(where(User, id: ^user.id))
      Sandbox.checkin(Repo)
    end
  end

  defp concurrent(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp backend do
    [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    pid
  end

  defp blocked?(waiter, holder) do
    Enum.any?(1..200, fn _ ->
      [[blocked]] = Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [holder, waiter]).rows
      if !blocked, do: Process.sleep(10)
      blocked
    end)
  end
end
