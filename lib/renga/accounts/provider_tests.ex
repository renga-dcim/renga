defmodule Renga.Accounts.ProviderTests do
  @moduledoc """
  Test sign-ins of a pending provider revision (RFD 15, "Storage and
  changes"). An operator or administrator creates a test with
  `IdentityProviders.create_test/2` and opens its single-use link; Renga
  sends the browser to the provider with the pending revision's settings,
  and a successful callback activates exactly that revision.

  A test never signs anyone in. Its callback validates the ID token and
  activates the revision, and that is all: it creates no session, links no
  identity, and leaves no account re-check evidence. The test's state,
  nonce, and PKCE verifier live on its row rather than in the browser
  session, so a test works from a browser with no Renga session at all, such
  as during recovery.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.IdentityProviderTest
  alias Renga.Accounts.OIDC
  alias Renga.Repo

  @doc """
  Opens a test from its link: claims the token, which works once, and
  returns the provider's authorization URL for the pending revision.
  `redirect_uri` builds the callback URL from the provider's ID.
  """
  def start(token, redirect_uri) when is_binary(token) and is_function(redirect_uri, 1) do
    with {:ok, test} <- claim(token),
         {:ok, provider, revision} <- pending(test),
         true <- provider.kind == "oidc" || {:error, :unsupported},
         {:ok, url, attempt} <- OIDC.authorize(provider, revision, redirect_uri.(provider.id)) do
      test
      |> Ecto.Changeset.change(
        state_hash: hash(attempt["state"]),
        nonce: attempt["nonce"],
        verifier: attempt["verifier"]
      )
      |> Repo.update!()

      {:ok, url}
    end
  end

  @doc "The started, unfinished test a callback's `state` belongs to, or nil."
  def for_state(state) when is_binary(state) do
    now = Renga.Time.utc_now_ms()

    IdentityProviderTest
    |> where(state_hash: ^hash(state))
    |> where([test], is_nil(test.completed_at) and test.expires_at > ^now)
    |> Repo.one()
  end

  def for_state(_state), do: nil

  @doc """
  Finishes `test` from the provider's callback: validates the ID token with
  the pending revision, then activates it. Returns the activated provider.
  """
  def finish(%IdentityProviderTest{} = test, %{"provider" => id} = params, redirect_uri) do
    attempt = %{"nonce" => test.nonce, "verifier" => test.verifier}

    with true <- id == test.provider_id || {:error, :provider_mismatch},
         {:ok, provider, revision} <- pending(test),
         {:ok, _validated} <- OIDC.exchange(provider, revision, attempt, params, redirect_uri) do
      IdentityProviders.activate_tested(test)
    end
  end

  # Marks the token used, so a link opens at most one test.
  defp claim(token) do
    now = Renga.Time.utc_now_ms()

    IdentityProviderTest
    |> where(token_hash: ^hash(token))
    |> where([test], is_nil(test.started_at) and test.expires_at > ^now)
    |> select([test], test)
    |> Repo.update_all(set: [started_at: now])
    |> case do
      {1, [test]} -> {:ok, test}
      _other -> {:error, :test_expired}
    end
  end

  defp pending(%IdentityProviderTest{provider_id: id, revision: number}) do
    case IdentityProviders.get(id) do
      %IdentityProvider{pending_revision: ^number} = provider ->
        {:ok, provider, IdentityProviders.revision(provider, number)}

      _changed_or_removed ->
        {:error, :revision_changed}
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value)
end
