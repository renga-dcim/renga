defmodule Renga.Accounts.MFAKeyRotationTest do
  # Changes the Vault keys in the application environment, so not async.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts.MFA
  alias Renga.Accounts.UserTOTP

  setup do
    previous = Application.get_env(:renga, Renga.Vault)
    on_exit(fn -> Application.put_env(:renga, Renga.Vault, previous) end)
    %{old_spec: previous[:keys]}
  end

  defp code(secret, steps \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + steps * 30)

  defp key_id(user), do: Repo.one!(where(UserTOTP, user_id: ^user.id)).secret_key_id

  test "rotating keys reseals secrets so the old key can be retired", %{old_spec: old_spec} do
    used = user_fixture()
    idle = user_fixture()
    used_secret = MFA.new_totp_secret()
    idle_secret = MFA.new_totp_secret()
    {:ok, _} = MFA.enable_totp(used, used_secret, code(used_secret, -1))
    {:ok, _} = MFA.enable_totp(idle, idle_secret, code(idle_secret, -1))

    new_spec = "next:" <> Base.encode64(:crypto.strong_rand_bytes(32))
    Application.put_env(:renga, Renga.Vault, keys: new_spec <> "," <> old_spec)

    # Using a secret reseals it under the new key.
    assert :ok = MFA.verify_totp(used, code(used_secret))
    assert key_id(used) == "next"
    assert key_id(idle) != "next"

    assert {:ok, 1} = MFA.reencrypt_totp_secrets()
    assert key_id(idle) == "next"
    assert {:ok, 0} = MFA.reencrypt_totp_secrets()

    Application.put_env(:renga, Renga.Vault, keys: new_spec)
    assert :ok = MFA.verify_totp(idle, code(idle_secret))
  end

  test "without a key no authenticator app can be added" do
    Application.put_env(:renga, Renga.Vault, keys: [])
    user = user_fixture()
    secret = MFA.new_totp_secret()

    refute MFA.totp_available?()
    assert {:error, :no_encryption_key} = MFA.enable_totp(user, secret, code(secret))
    refute MFA.totp_enabled?(user)
  end
end
