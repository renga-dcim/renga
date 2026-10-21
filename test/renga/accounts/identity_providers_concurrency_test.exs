defmodule Renga.Accounts.IdentityProvidersConcurrencyTest do
  @moduledoc """
  Provider changes serialize on one lock, so the guard that keeps a way to
  sign in sees each change's result before the next one is checked.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderEvent
  alias Renga.Accounts.IdentityProviderRevision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Repo

  @operator {:operator, "release"}

  test "two disables cannot together remove the last two ways to sign in" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    providers = for _ <- 1..2, do: active_provider()
    Application.put_env(:renga, :local_sign_in, :disabled)

    try do
      [a, b] = providers

      assert {{:ok, _}, {:error, :last_sign_in_method}} =
               race(fn -> IdentityProviders.disable(a, @operator) end, fn ->
                 IdentityProviders.disable(b, @operator)
               end)

      assert IdentityProviders.sign_in_available?()
    after
      Application.delete_env(:renga, :local_sign_in)
      # Only what this test committed outside the sandbox.
      ids = Enum.map(providers, & &1.id)
      Repo.delete_all(where(IdentityProviderEvent, [e], e.provider_id in ^ids))
      Repo.delete_all(where(IdentityProviderRevision, [r], r.provider_id in ^ids))
      Repo.delete_all(where(IdentityProvider, [p], p.id in ^ids))
      Sandbox.checkin(Repo)
    end
  end

  defp active_provider do
    {:ok, {provider, _revision}} =
      IdentityProviders.create(
        %{
          "id" => "idp-#{System.unique_integer([:positive])}",
          "kind" => "oidc",
          "issuer" => "https://idp.example.com/",
          "display_name" => "IdP",
          "client_id" => "renga",
          "client_secret" => "s3cret"
        },
        @operator
      )

    # Activation arrives with test sign-in; until then it is set directly.
    provider
    |> Ecto.Changeset.change(active_revision: 1, pending_revision: nil)
    |> Repo.update!()
  end
end
