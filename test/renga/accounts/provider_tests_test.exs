defmodule Renga.Accounts.ProviderTestsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.ProviderTests
  alias Renga.Accounts.UserIdentity
  alias Renga.FakeOIDCProvider

  @operator {:operator, "release"}

  setup do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    %{fake: fake}
  end

  defp redirect_uri(id), do: "http://localhost:4002/users/auth/#{id}/callback"

  defp new_provider(fake) do
    {:ok, {provider, _}} =
      IdentityProviders.create(
        %{
          "id" => "idp-#{System.unique_integer([:positive])}",
          "kind" => "oidc",
          "issuer" => fake.issuer,
          "display_name" => "Company SSO",
          "client_id" => fake.client_id,
          "client_secret" => "client-secret",
          "allow_sign_up" => true
        },
        @operator
      )

    provider
  end

  defp run_test(fake, provider, opts \\ []) do
    {:ok, {token, _test}} = IdentityProviders.create_test(provider, @operator)
    {:ok, url} = ProviderTests.start(token, &redirect_uri/1)
    params = FakeOIDCProvider.authorize(fake, url, %{"sub" => "tester"}, opts)
    test = ProviderTests.for_state(params["state"])
    {test, Map.put(params, "provider", provider.id)}
  end

  test "a successful test activates the pending revision", %{fake: fake} do
    provider = new_provider(fake)
    refute IdentityProviders.usable?(provider)

    {test, params} = run_test(fake, provider)
    assert {:ok, activated} = ProviderTests.finish(test, params, redirect_uri(provider.id))

    assert activated.active_revision == 1
    assert activated.pending_revision == nil
    assert IdentityProviders.usable?(activated)

    assert [%{kind: "activated", revision: 1, actor: "operator: release"} | _] =
             IdentityProviders.list_events(activated)
  end

  test "a test signs nobody in and links no identity", %{fake: fake} do
    provider = new_provider(fake)
    {test, params} = run_test(fake, provider)
    {:ok, _} = ProviderTests.finish(test, params, redirect_uri(provider.id))

    refute Repo.get_by(UserIdentity, provider_id: provider.id)
  end

  test "tests the pending revision while the active one keeps working", %{fake: fake} do
    provider = identity_provider_fixture(fake)

    {:ok, {provider, _}} =
      IdentityProviders.propose_revision(provider, %{"scopes" => ["groups"]}, @operator)

    {:ok, {token, _}} = IdentityProviders.create_test(provider, @operator)
    {:ok, url} = ProviderTests.start(token, &redirect_uri/1)
    assert url =~ "groups"

    assert IdentityProviders.usable?(provider)
    assert IdentityProviders.active_revision(provider).scopes == []
  end

  test "a failed test activates nothing", %{fake: fake} do
    provider = new_provider(fake)
    {test, params} = run_test(fake, provider, aud: "another-client")

    assert {:error, _reason} = ProviderTests.finish(test, params, redirect_uri(provider.id))
    refute IdentityProviders.usable?(IdentityProviders.get(provider.id))
  end

  test "another edit makes the test result stale", %{fake: fake} do
    provider = new_provider(fake)
    {test, params} = run_test(fake, provider)

    {:ok, _} =
      IdentityProviders.propose_revision(provider, %{"client_secret" => "rotated"}, @operator)

    assert {:error, :revision_changed} =
             ProviderTests.finish(test, params, redirect_uri(provider.id))

    assert IdentityProviders.get(provider.id).active_revision == nil
  end

  test "a test link opens once", %{fake: fake} do
    provider = new_provider(fake)
    {:ok, {token, _}} = IdentityProviders.create_test(provider, @operator)

    assert {:ok, _url} = ProviderTests.start(token, &redirect_uri/1)
    assert {:error, :test_expired} = ProviderTests.start(token, &redirect_uri/1)
    assert {:error, :test_expired} = ProviderTests.start("made-up", &redirect_uri/1)
  end

  test "a test result activates once", %{fake: fake} do
    provider = new_provider(fake)
    {test, params} = run_test(fake, provider)
    {:ok, _} = ProviderTests.finish(test, params, redirect_uri(provider.id))

    assert ProviderTests.for_state(params["state"]) == nil
    assert {:error, :test_expired} = IdentityProviders.activate_tested(test)
  end

  test "a test callback for another provider fails", %{fake: fake} do
    provider = new_provider(fake)
    other = new_provider(fake)
    {test, params} = run_test(fake, provider)

    assert {:error, :provider_mismatch} =
             ProviderTests.finish(
               test,
               %{params | "provider" => other.id},
               redirect_uri(other.id)
             )
  end

  test "nothing to test without a pending revision", %{fake: fake} do
    provider = identity_provider_fixture(fake)
    assert {:error, :nothing_pending} = IdentityProviders.create_test(provider, @operator)
  end
end
