defmodule Renga.ScimFixtures do
  @moduledoc "SCIM connections and tokens for tests."

  import Renga.AccountsFixtures, only: [identity_provider_fixture: 2]

  alias Renga.FakeOIDCProvider

  @doc "An enabled `oidc` deployment provider; it is never contacted."
  def scim_provider_fixture(attrs \\ %{}),
    do: identity_provider_fixture(FakeOIDCProvider.new(), attrs)

  @doc "A connection made by `owner`, an owner's scope, to a new provider unless one is given."
  def scim_connection_fixture(owner, attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, "provider_id", fn -> scim_provider_fixture().id end)
    {:ok, connection} = Renga.Scim.create_connection(owner, attrs)
    connection
  end

  @doc "A token for `connection` and its value."
  def scim_token_fixture(owner, connection, name \\ "Okta") do
    {:ok, {token, value}} = Renga.Scim.create_token(owner, connection.id, %{"name" => name})
    {token, value}
  end
end
