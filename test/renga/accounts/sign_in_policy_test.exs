defmodule Renga.Accounts.SignInPolicyTest do
  # Changes the application's sign-in settings.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.LocalSignInOverride
  alias Renga.Accounts.SignInPolicy
  alias Renga.FakeOIDCProvider

  setup do
    Application.put_env(:renga, :local_sign_in, :disabled)
    on_exit(fn -> Application.delete_env(:renga, :local_sign_in) end)
  end

  test "defaults to open registration and local sign-in" do
    Application.delete_env(:renga, :local_sign_in)
    assert SignInPolicy.registration_open?()
    assert SignInPolicy.local_sign_in?()
    refute SignInPolicy.recovery_mode?()
  end

  test "with local sign-in off and no provider, the deployment is in recovery mode" do
    refute SignInPolicy.local_sign_in?()
    assert SignInPolicy.recovery_mode?()

    FakeOIDCProvider.stub(fake = FakeOIDCProvider.new())
    identity_provider_fixture(fake)
    refute SignInPolicy.recovery_mode?()
  end

  test "an override turns local sign-in on until it expires or is revoked" do
    assert {:ok, override} = SignInPolicy.recover_local(30, "jane")
    assert SignInPolicy.local_sign_in?()
    refute SignInPolicy.configured_local_sign_in?()
    assert DateTime.diff(override.expires_at, Renga.Time.utc_now_ms(), :minute) in 29..30

    assert {:ok, 1} = SignInPolicy.revoke_overrides("jane")
    refute SignInPolicy.local_sign_in?()
    assert Repo.get!(LocalSignInOverride, override.id).revoked_by == "jane"
  end

  test "an expired override does nothing" do
    {:ok, override} = SignInPolicy.recover_local(30, "jane")

    override
    |> Ecto.Changeset.change(expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1, :second))
    |> Repo.update!()

    refute SignInPolicy.local_sign_in?()
  end

  test "an override never opens registration" do
    Application.put_env(:renga, :registration, :closed)
    on_exit(fn -> Application.delete_env(:renga, :registration) end)

    {:ok, _} = SignInPolicy.recover_local(30, "jane")
    refute SignInPolicy.registration_open?()
  end

  test "an override can take a broken sole provider out of service in one step" do
    FakeOIDCProvider.stub(fake = FakeOIDCProvider.new())
    provider = identity_provider_fixture(fake)

    assert {:error, :last_sign_in_method} =
             IdentityProviders.disable(provider, {:operator, "jane"})

    assert {:ok, _override} = SignInPolicy.recover_local(60, "jane", disable: provider.id)

    refute IdentityProviders.get(provider.id).enabled
    assert SignInPolicy.local_sign_in?()
  end

  test "limits an override to a day" do
    assert_raise FunctionClauseError, fn -> SignInPolicy.recover_local(24 * 60 + 1, "jane") end
    assert_raise FunctionClauseError, fn -> SignInPolicy.recover_local(0, "jane") end
  end
end
