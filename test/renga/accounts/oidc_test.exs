defmodule Renga.Accounts.OIDCTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts.Identities
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OIDC
  alias Renga.Accounts.UserIdentity
  alias Renga.FakeOIDCProvider

  @redirect_uri "http://localhost:4002/users/auth/callback"

  setup do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    %{fake: fake, provider: identity_provider_fixture(fake)}
  end

  defp sign_in(fake, provider, claims, opts \\ []) do
    {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
    params = FakeOIDCProvider.authorize(fake, url, claims, opts)
    {attempt, params, OIDC.finish(attempt, params, @redirect_uri)}
  end

  defp flush_token_requests do
    receive do
      {FakeOIDCProvider, :token_requested} -> flush_token_requests()
    after
      0 -> :ok
    end
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{"sub" => "subject-1", "email" => "pat@example.com", "email_verified" => true},
      overrides
    )
  end

  describe "start/3" do
    test "asks for the code flow with PKCE, state, nonce, and the provider's scopes", %{
      fake: fake
    } do
      provider = identity_provider_fixture(fake, %{"scopes" => ["groups"]})
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == fake.issuer <> "/authorize"
      assert query["response_type"] == "code"
      assert query["client_id"] == "renga"
      assert query["redirect_uri"] == @redirect_uri
      assert query["state"] == attempt["state"]
      assert query["nonce"] == attempt["nonce"]
      assert query["code_challenge_method"] == "S256"
      refute query["code_challenge"] == attempt["verifier"]
      assert String.split(query["scope"]) == ["openid", "email", "profile", "groups"]
      assert attempt["revision"] == 1
    end

    test "accepts a plain-HTTP issuer on localhost, for development" do
      port = rem(System.unique_integer([:positive]), 50_000) + 10_000
      fake = FakeOIDCProvider.new(issuer: "http://localhost:#{port}")
      FakeOIDCProvider.stub(fake)
      provider = identity_provider_fixture(fake)

      assert {:ok, url, _attempt} = OIDC.start(provider, @redirect_uri)
      assert String.starts_with?(url, fake.issuer <> "/authorize?")
    end

    test "refuses a provider whose endpoints are not https or offer only plain PKCE", %{
      fake: fake
    } do
      for discovery <- [
            %{"token_endpoint" => "http://idp.example.com/token"},
            %{"jwks_uri" => "http://idp.example.com/jwks"},
            %{"authorization_endpoint" => "http://idp.example.com/authorize"},
            %{"code_challenge_methods_supported" => ["plain"]}
          ] do
        fake = %{fake | issuer: FakeOIDCProvider.new().issuer, discovery: discovery}
        FakeOIDCProvider.stub(fake)
        provider = identity_provider_fixture(fake)

        assert {:error, :provider_unavailable} = OIDC.start(provider, @redirect_uri)
      end
    end

    test "refuses a provider that is not active", %{fake: fake} do
      {:ok, {pending, _}} =
        IdentityProviders.create(
          %{
            "id" => "pending",
            "kind" => "oidc",
            "issuer" => fake.issuer,
            "display_name" => "Pending",
            "client_id" => "renga",
            "client_secret" => "x"
          },
          {:operator, "test"}
        )

      assert {:error, :inactive} = OIDC.start(pending, @redirect_uri)
    end
  end

  describe "finish/3" do
    test "returns the validated claims", %{fake: fake, provider: provider} do
      {_attempt, _params, result} = sign_in(fake, provider, claims())

      assert {:ok, %{provider: %{id: id}, revision: %{number: 1}, claims: claims}} = result
      assert id == provider.id
      assert claims["sub"] == "subject-1"
      assert claims["email"] == "pat@example.com"
    end

    test "rejects another state", %{fake: fake, provider: provider} do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())

      assert {:error, :state_mismatch} =
               OIDC.finish(attempt, %{params | "state" => "forged"}, @redirect_uri)

      assert {:error, :state_mismatch} =
               OIDC.finish(attempt, Map.delete(params, "state"), @redirect_uri)
    end

    test "rejects a token with another nonce", %{fake: fake, provider: provider} do
      {_attempt, _params, result} = sign_in(fake, provider, claims(), nonce: "replayed")
      assert {:error, :invalid_response} = result
    end

    test "rejects a token for another client", %{fake: fake, provider: provider} do
      {_attempt, _params, result} = sign_in(fake, provider, claims(), aud: "someone-else")
      assert {:error, :invalid_response} = result
    end

    test "rejects an expired token", %{fake: fake, provider: provider} do
      past = System.system_time(:second) - 60
      {_attempt, _params, result} = sign_in(fake, provider, claims(), exp: past)
      assert {:error, :token_expired} = result
    end

    test "rejects a token signed with an unknown key", %{fake: fake, provider: provider} do
      other = JOSE.JWK.generate_key({:ec, "P-256"})
      # An unknown key reloads the key set once before failing.
      {_attempt, _params, result} = sign_in(fake, provider, claims(), jwk: other, kid: "rotated")
      assert {:error, _reason} = result
    end

    test "rejects a callback naming another issuer", %{fake: fake, provider: provider} do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())

      assert {:error, :issuer_mismatch} =
               OIDC.finish(
                 attempt,
                 %{params | "iss" => "https://evil.example.com"},
                 @redirect_uri
               )
    end

    test "rejects an error response", %{fake: fake, provider: provider} do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())

      assert {:error, :denied} =
               OIDC.finish(attempt, Map.put(params, "error", "access_denied"), @redirect_uri)
    end

    test "rejects a stale attempt", %{fake: fake, provider: provider} do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())
      attempt = %{attempt | "started_at" => attempt["started_at"] - 11 * 60}

      assert {:error, :expired} = OIDC.finish(attempt, params, @redirect_uri)
    end

    test "fails once the provider is disabled or its active revision changes", %{
      fake: fake,
      provider: provider
    } do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())

      provider |> Ecto.Changeset.change(active_revision: 2) |> Repo.update!()
      assert {:error, :provider_changed} = OIDC.finish(attempt, params, @redirect_uri)

      {:ok, _} = IdentityProviders.disable(provider, {:operator, "test"})
      assert {:error, :inactive} = OIDC.finish(attempt, params, @redirect_uri)
    end

    test "an attempt finishes once, even from a copied session", %{
      fake: fake,
      provider: provider
    } do
      {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
      params = FakeOIDCProvider.authorize(fake, url, claims())
      assert {:ok, _} = OIDC.finish(attempt, params, @redirect_uri)

      # A fresh code from the same authorization request, with the saved
      # attempt, is refused before any token request.
      params = FakeOIDCProvider.authorize(fake, url, claims())
      flush_token_requests()
      assert {:error, :attempt_used} = OIDC.finish(attempt, params, @redirect_uri)
      refute_received {FakeOIDCProvider, :token_requested}
    end

    test "a provider that promised iss must send it, as a string", %{fake: fake} do
      fake = %{fake | discovery: %{"authorization_response_iss_parameter_supported" => true}}
      FakeOIDCProvider.stub(fake)
      provider = identity_provider_fixture(fake)

      for change <- [&Map.delete(&1, "iss"), &Map.put(&1, "iss", %{"x" => fake.issuer})] do
        {:ok, url, attempt} = OIDC.start(provider, @redirect_uri)
        params = fake |> FakeOIDCProvider.authorize(url, claims()) |> change.()
        flush_token_requests()

        assert {:error, :issuer_mismatch} = OIDC.finish(attempt, params, @redirect_uri)
        refute_received {FakeOIDCProvider, :token_requested}
      end
    end

    test "a token response without an ID token is refused, not raised", %{fake: fake} do
      fake = %{fake | id_token: false}
      FakeOIDCProvider.stub(fake)
      provider = identity_provider_fixture(fake)

      {_attempt, _params, result} = sign_in(fake, provider, claims())
      assert {:error, :invalid_response} = result
    end
  end

  describe "Accounts.finish_provider_sign_in/2" do
    test "creates nothing once the provider changed after the token exchange", %{
      fake: fake,
      provider: provider
    } do
      {_attempt, _params, {:ok, result}} = sign_in(fake, provider, claims())
      {:ok, _} = IdentityProviders.disable(provider, {:operator, "test"})

      assert {:error, :inactive} =
               Renga.Accounts.finish_provider_sign_in(result, fn _user -> {:ok, :issued} end)

      refute Repo.get_by(Renga.Accounts.User, email: "pat@example.com")
    end

    test "rolls a new account back when the session is not issued", %{
      fake: fake,
      provider: provider
    } do
      {_attempt, _params, {:ok, result}} = sign_in(fake, provider, claims())

      assert {:error, :session_failed} =
               Renga.Accounts.finish_provider_sign_in(result, fn _user ->
                 {:error, :session_failed}
               end)

      refute Repo.get_by(Renga.Accounts.User, email: "pat@example.com")
      refute Repo.get_by(UserIdentity, subject: "subject-1")
    end
  end

  describe "Identities.resolve/1" do
    test "signs up a verified email and links the subject", %{fake: fake, provider: provider} do
      {_, _, {:ok, result}} = sign_in(fake, provider, claims())

      assert {:ok, user} = Identities.resolve(result)
      assert user.email == "pat@example.com"
      assert user.confirmed_at
      refute user.hashed_password

      assert %UserIdentity{user_id: user_id} =
               Repo.get_by(UserIdentity, provider_id: provider.id, subject: "subject-1")

      assert user_id == user.id
    end

    test "a returning sign-in matches the subject, not the email", %{
      fake: fake,
      provider: provider
    } do
      {_, _, {:ok, first}} = sign_in(fake, provider, claims())
      {:ok, user} = Identities.resolve(first)

      {_, _, {:ok, again}} = sign_in(fake, provider, claims(%{"email" => "pat@other.example"}))
      assert {:ok, same} = Identities.resolve(again)
      assert same.id == user.id

      {_, _, {:ok, other}} =
        sign_in(fake, provider, claims(%{"sub" => "subject-2", "email" => "new@example.com"}))

      assert {:ok, different} = Identities.resolve(other)
      refute different.id == user.id
    end

    test "an unverified email does not say whether an account uses it", %{
      fake: fake,
      provider: provider
    } do
      user_fixture(%{email: "pat@example.com"})

      {_attempt, _params, {:ok, result}} =
        sign_in(fake, provider, claims(%{"email_verified" => false}))

      assert {:error, :unverified_email} = Identities.resolve(result)
    end

    test "never links to an existing account by email", %{fake: fake, provider: provider} do
      existing = user_fixture(%{email: "pat@example.com"})
      {_, _, {:ok, result}} = sign_in(fake, provider, claims(%{"email" => "PAT@example.com"}))

      assert {:error, :email_in_use} = Identities.resolve(result)
      refute Repo.get_by(UserIdentity, user_id: existing.id)
    end

    test "refuses sign-up when the provider does not allow it", %{fake: fake} do
      provider = identity_provider_fixture(fake, %{"allow_sign_up" => false})
      {_, _, {:ok, result}} = sign_in(fake, provider, claims())

      assert {:error, :sign_up_closed} = Identities.resolve(result)
    end

    test "refuses sign-up from an unverified email", %{fake: fake, provider: provider} do
      {_, _, {:ok, result}} = sign_in(fake, provider, claims(%{"email_verified" => false}))
      assert {:error, :unverified_email} = Identities.resolve(result)

      {_, _, {:ok, result}} = sign_in(fake, provider, claims() |> Map.delete("email"))
      assert {:error, :unverified_email} = Identities.resolve(result)
    end

    test "the email domain allowlist applies to every sign-in", %{fake: fake} do
      provider = identity_provider_fixture(fake, %{"email_domains" => ["example.com"]})
      {_, _, {:ok, result}} = sign_in(fake, provider, claims())
      assert {:ok, _user} = Identities.resolve(result)

      {_, _, {:ok, result}} = sign_in(fake, provider, claims(%{"email" => "pat@elsewhere.test"}))
      assert {:error, :domain_not_allowed} = Identities.resolve(result)

      {_, _, {:ok, result}} = sign_in(fake, provider, claims(%{"email_verified" => false}))
      assert {:error, :domain_not_allowed} = Identities.resolve(result)
    end
  end
end
