defmodule Renga.Accounts.IdentityProvidersTest do
  # Some tests turn local sign-in off for the whole application.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision
  alias Renga.Accounts.IdentityProviders

  @operator {:operator, "release"}

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "okta-#{System.unique_integer([:positive])}",
        "kind" => "oidc",
        "issuer" => "https://example.okta.com/",
        "display_name" => "Okta",
        "client_id" => "renga",
        "client_secret" => "s3cret",
        "email_domains" => ["Example.com", " example.com "],
        "scopes" => ["groups"]
      },
      overrides
    )
  end

  defp create(overrides \\ %{}) do
    {:ok, {provider, revision}} = IdentityProviders.create(attrs(overrides), @operator)
    {provider, revision}
  end

  # Activation arrives with test sign-in; until then tests set it directly.
  defp activate(%IdentityProvider{} = provider) do
    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Repo.update!()
  end

  defp without_local_sign_in(fun) do
    Application.put_env(:renga, :local_sign_in, :disabled)

    try do
      fun.()
    after
      Application.delete_env(:renga, :local_sign_in)
    end
  end

  defp event_kinds(provider),
    do: provider |> IdentityProviders.list_events() |> Enum.map(& &1.kind)

  describe "create/2" do
    test "saves the provider with revision 1 pending" do
      {provider, revision} = create()

      assert provider.issuer == "https://example.okta.com/"
      assert provider.pending_revision == 1
      assert provider.active_revision == nil
      refute IdentityProviders.usable?(provider)

      assert revision.number == 1
      assert revision.client_id == "renga"
      assert revision.email_domains == ["example.com"]
      assert revision.created_by == "operator: release"
      assert {:ok, "s3cret"} = IdentityProviders.client_secret(revision)
    end

    test "stores the secret encrypted and never in the clear" do
      {_provider, revision} = create()
      stored = Repo.get!(IdentityProviderRevision, revision.id)

      refute stored.client_secret_ciphertext =~ "s3cret"
      assert stored.client_secret_key_id == Renga.Vault.current_key_id()
      assert stored.client_secret == nil
      refute inspect(stored) =~ "s3cret"
    end

    test "records who created it and which fields were set, without the secret" do
      {provider, _revision} = create()

      assert [event] = IdentityProviders.list_events(provider)
      assert event.kind == "created"
      assert event.actor == "operator: release"
      assert "client_secret" in event.changed
      refute Enum.any?(event.changed, &(&1 =~ "s3cret"))
    end

    test "names a user actor" do
      user = user_fixture()
      {:ok, {provider, _}} = IdentityProviders.create(attrs(), {:user, user})

      assert [%{actor: actor, actor_user_id: user_id}] = IdentityProviders.list_events(provider)
      assert actor == user.email
      assert user_id == user.id
    end

    test "reports provider and revision errors together" do
      assert {:error, changeset} =
               IdentityProviders.create(
                 %{"id" => "Bad ID!", "kind" => "oidc", "issuer" => "http://evil.test"},
                 @operator
               )

      errors = errors_on(changeset)
      assert errors.id
      assert errors.issuer == ["must be an https URL without a query"]
      assert errors.display_name
      assert errors.client_id
      assert errors.client_secret
    end

    test "never reuses an ID, even after removal" do
      {provider, _} = create()
      {:ok, _} = IdentityProviders.remove(provider, @operator)

      assert {:error, changeset} =
               IdentityProviders.create(attrs(%{"id" => provider.id}), @operator)

      assert "is already taken" in errors_on(changeset).id
    end

    test "GitHub has no issuer and cannot sign people up" do
      assert {:ok, {provider, _}} =
               IdentityProviders.create(
                 attrs(%{"kind" => "github", "issuer" => nil, "display_name" => "GitHub"}),
                 @operator
               )

      assert provider.issuer == nil

      assert {:error, changeset} =
               IdentityProviders.create(
                 attrs(%{"kind" => "github", "issuer" => nil, "allow_sign_up" => true}),
                 @operator
               )

      assert errors_on(changeset).allow_sign_up
    end

    test "fails without an encryption key" do
      previous = Application.get_env(:renga, Renga.Vault)
      Application.put_env(:renga, Renga.Vault, keys: nil)

      try do
        assert {:error, :no_encryption_key} = IdentityProviders.create(attrs(), @operator)
      after
        Application.put_env(:renga, Renga.Vault, previous)
      end
    end
  end

  describe "propose_revision/3" do
    test "writes a pending revision while the active one stays in use" do
      {provider, _} = create()
      provider = activate(provider)

      assert {:ok, {provider, revision}} =
               IdentityProviders.propose_revision(
                 provider,
                 %{"client_id" => "renga-2"},
                 @operator
               )

      assert provider.active_revision == 1
      assert provider.pending_revision == 2
      assert IdentityProviders.active_revision(provider).client_id == "renga"
      assert revision.client_id == "renga-2"
      # An empty secret keeps the saved one.
      assert {:ok, "s3cret"} = IdentityProviders.client_secret(revision)

      assert Enum.any?(
               IdentityProviders.list_events(provider),
               &match?(%{kind: "revision_pending", revision: 2, changed: ["client_id"]}, &1)
             )
    end

    test "a new edit replaces the pending revision" do
      {provider, _} = create()

      {:ok, {provider, _}} =
        IdentityProviders.propose_revision(provider, %{"scopes" => []}, @operator)

      {:ok, {provider, revision}} =
        IdentityProviders.propose_revision(provider, %{"client_secret" => "new"}, @operator)

      assert provider.pending_revision == 3
      assert revision.scopes == []
      assert {:ok, "new"} = IdentityProviders.client_secret(revision)
    end

    test "refuses an edit that changes nothing" do
      {provider, _} = create()

      assert {:error, :no_changes} =
               IdentityProviders.propose_revision(
                 provider,
                 %{"client_id" => "renga", "client_secret" => ""},
                 @operator
               )
    end

    test "reports invalid settings" do
      {provider, _} = create()

      assert {:error, changeset} =
               IdentityProviders.propose_revision(
                 provider,
                 %{"email_domains" => ["not a domain"], "session_lifetime_seconds" => 10},
                 @operator
               )

      assert errors_on(changeset).email_domains
      assert errors_on(changeset).session_lifetime_seconds
    end
  end

  test "discard_pending/2 keeps a new provider's only revision" do
    {provider, _} = create()

    assert {:error, :no_active_revision} = IdentityProviders.discard_pending(provider, @operator)
    assert IdentityProviders.get(provider.id).pending_revision == 1
    refute "revision_discarded" in event_kinds(provider)

    assert {:ok, {_provider, %{number: 2}}} =
             IdentityProviders.propose_revision(provider, %{"client_id" => "renga-2"}, @operator)
  end

  test "discard_pending/2 keeps the active revision" do
    {provider, _} = create()
    provider = activate(provider)

    {:ok, {provider, _}} =
      IdentityProviders.propose_revision(provider, %{"client_id" => "x"}, @operator)

    assert {:ok, provider} = IdentityProviders.discard_pending(provider, @operator)
    assert provider.pending_revision == nil
    assert provider.active_revision == 1
    assert {:error, :nothing_pending} = IdentityProviders.discard_pending(provider, @operator)
  end

  test "update_display/3 changes display fields in place" do
    {provider, _} = create()

    assert {:ok, updated} =
             IdentityProviders.update_display(
               provider,
               %{"display_name" => "Company SSO", "hidden" => true},
               @operator
             )

    assert updated.display_name == "Company SSO"
    assert updated.hidden
    assert updated.pending_revision == 1
    assert updated.version == provider.version + 1

    # It may share a millisecond with "created", so look for it.
    assert Enum.any?(
             IdentityProviders.list_events(updated),
             &match?(%{kind: "updated", changed: ["display_name", "hidden"]}, &1)
           )
  end

  test "every change increments the version" do
    {provider, _} = create()
    provider = activate(provider)
    {:ok, disabled} = IdentityProviders.disable(provider, @operator)
    {:ok, enabled} = IdentityProviders.enable(disabled, @operator)

    assert disabled.version == provider.version + 1
    assert enabled.version == disabled.version + 1
    assert IdentityProviders.usable?(enabled)
  end

  describe "remove/2" do
    test "hides the provider, keeps its ID reserved, and drops its secrets" do
      {provider, revision} = create()
      {:ok, removed} = IdentityProviders.remove(provider, @operator)

      assert removed.removed_at
      refute IdentityProviders.get(provider.id)
      refute Enum.any?(IdentityProviders.list(), &(&1.id == provider.id))

      assert {:error, :no_secret} =
               IdentityProviders.client_secret(Repo.get!(IdentityProviderRevision, revision.id))

      assert "removed" in event_kinds(provider)
      assert {:error, :not_found} = IdentityProviders.enable(removed, @operator)
    end
  end

  describe "the sign-in guard" do
    test "refuses to disable or remove the last way to sign in" do
      {provider, _} = create()
      provider = activate(provider)

      without_local_sign_in(fn ->
        assert {:error, :last_sign_in_method} = IdentityProviders.disable(provider, @operator)
        assert {:error, :last_sign_in_method} = IdentityProviders.remove(provider, @operator)
      end)

      provider = IdentityProviders.get(provider.id)
      assert IdentityProviders.usable?(provider)
      refute "disabled" in event_kinds(provider)

      assert {:ok, _} =
               IdentityProviders.client_secret(IdentityProviders.active_revision(provider))
    end

    test "lets a deployment with no way to sign in set up its first provider" do
      without_local_sign_in(fn ->
        {provider, _} = create()
        refute IdentityProviders.usable?(provider)

        assert {:ok, _} =
                 IdentityProviders.update_display(provider, %{"display_name" => "SSO"}, @operator)

        assert {:ok, _} =
                 IdentityProviders.propose_revision(provider, %{"client_id" => "x"}, @operator)
      end)
    end

    test "allows it while another provider can sign people in" do
      {first, _} = create()
      {second, _} = create()
      first = activate(first)
      activate(second)

      without_local_sign_in(fn ->
        assert {:ok, _} = IdentityProviders.disable(first, @operator)
      end)
    end

    test "allows anything while local sign-in works" do
      {provider, _} = create()
      provider = activate(provider)

      assert IdentityProviders.sign_in_available?()
      assert {:ok, _} = IdentityProviders.disable(provider, @operator)
    end
  end

  describe "reencrypt_secrets/1" do
    test "moves every secret to the current key so the old one can go" do
      previous = Application.get_env(:renga, Renga.Vault)
      old = Base.encode64(:crypto.strong_rand_bytes(32))
      new = Base.encode64(:crypto.strong_rand_bytes(32))

      try do
        Application.put_env(:renga, Renga.Vault, keys: "old:#{old}")
        {provider, revision} = create()

        Application.put_env(:renga, Renga.Vault, keys: "new:#{new},old:#{old}")
        assert {:ok, 1} = IdentityProviders.reencrypt_secrets(@operator)
        version = IdentityProviders.get(provider.id).version
        assert version == provider.version + 1

        # Nothing left to reseal changes nothing.
        assert {:ok, 0} = IdentityProviders.reencrypt_secrets(@operator)
        assert IdentityProviders.get(provider.id).version == version
        assert Enum.count(event_kinds(provider), &(&1 == "secret_reencrypted")) == 1

        Application.put_env(:renga, Renga.Vault, keys: "new:#{new}")
        revision = Repo.get!(IdentityProviderRevision, revision.id)
        assert revision.client_secret_key_id == "new"
        assert {:ok, "s3cret"} = IdentityProviders.client_secret(revision)
        assert "secret_reencrypted" in event_kinds(provider)
      after
        Application.put_env(:renga, Renga.Vault, previous)
      end
    end

    test "the release command reseals provider secrets too" do
      previous = Application.get_env(:renga, Renga.Vault)
      old = Base.encode64(:crypto.strong_rand_bytes(32))
      new = Base.encode64(:crypto.strong_rand_bytes(32))

      try do
        Application.put_env(:renga, Renga.Vault, keys: "old:#{old}")
        {_provider, revision} = create()

        Application.put_env(:renga, Renga.Vault, keys: "new:#{new},old:#{old}")

        assert ExUnit.CaptureIO.capture_io(fn -> Renga.Release.reencrypt_secrets() end) =~
                 "1 identity provider secrets"

        assert Repo.get!(IdentityProviderRevision, revision.id).client_secret_key_id == "new"
      after
        Application.put_env(:renga, Renga.Vault, previous)
      end
    end

    test "refuses without a key instead of crashing" do
      previous = Application.get_env(:renga, Renga.Vault)
      Application.put_env(:renga, Renga.Vault, keys: nil)

      try do
        assert {:error, :no_key} = IdentityProviders.reencrypt_secrets(@operator)
      after
        Application.put_env(:renga, Renga.Vault, previous)
      end
    end
  end

  test "a secret copied to another provider does not decrypt" do
    {_a, revision_a} = create()
    {_b, revision_b} = create()

    copied = %{
      revision_b
      | client_secret_ciphertext: revision_a.client_secret_ciphertext,
        client_secret_key_id: revision_a.client_secret_key_id
    }

    assert {:error, :invalid} = IdentityProviders.client_secret(copied)
  end
end
