defmodule Renga.Accounts.MFATest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts.MFA
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.UserRecoveryCode
  alias Renga.Accounts.UserTOTP

  defp code_for(secret, steps_from_now \\ 0) do
    NimbleTOTP.verification_code(secret, time: System.os_time(:second) + steps_from_now * 30)
  end

  defp events(user, kind) do
    Repo.aggregate(where(SecurityEvent, user_id: ^user.id, kind: ^kind), :count)
  end

  describe "enable_totp/3" do
    test "the first factor turns on MFA and returns ten recovery codes" do
      user = user_fixture()
      secret = MFA.new_totp_secret()

      assert {:ok, codes} = MFA.enable_totp(user, secret, code_for(secret))
      assert length(codes) == 10
      assert length(Enum.uniq(codes)) == 10
      assert MFA.mfa?(user)
      assert MFA.recovery_codes_left(user) == 10
      assert events(user, "totp_added") == 1

      refute Repo.exists?(where(UserRecoveryCode, code_hash: ^hd(codes)))
    end

    test "a wrong code saves nothing" do
      user = user_fixture()
      secret = MFA.new_totp_secret()

      assert {:error, :invalid_code} = MFA.enable_totp(user, secret, "000000")
      refute MFA.mfa?(user)
    end

    test "an account has one authenticator app" do
      user = user_fixture()
      secret = MFA.new_totp_secret()
      {:ok, _codes} = MFA.enable_totp(user, secret, code_for(secret))

      other = MFA.new_totp_secret()
      assert {:error, :already_enabled} = MFA.enable_totp(user, other, code_for(other))
    end
  end

  describe "verify_totp/2" do
    setup do
      user = user_fixture()
      secret = MFA.new_totp_secret()
      {:ok, _codes} = MFA.enable_totp(user, secret, code_for(secret, -1))
      %{user: user, secret: secret}
    end

    test "accepts a current code once", %{user: user, secret: secret} do
      code = code_for(secret)

      assert :ok = MFA.verify_totp(user, code)
      assert {:error, :invalid_code} = MFA.verify_totp(user, code)
    end

    test "never accepts a step older than the last accepted one", %{user: user, secret: secret} do
      assert :ok = MFA.verify_totp(user, code_for(secret, 1))
      assert {:error, :invalid_code} = MFA.verify_totp(user, code_for(secret))
    end

    test "rejects codes outside the drift window", %{user: user, secret: secret} do
      assert {:error, :invalid_code} = MFA.verify_totp(user, code_for(secret, 3))
    end

    test "records every failure and stops after ten", %{user: user, secret: secret} do
      for _ <- 1..10, do: assert({:error, :invalid_code} = MFA.verify_totp(user, "000000"))

      assert events(user, "totp_failed") == 10
      assert {:error, :rate_limited} = MFA.verify_totp(user, code_for(secret))
    end

    test "an account without an app has nothing to verify" do
      assert {:error, :not_enabled} = MFA.verify_totp(user_fixture(), "123456")
    end
  end

  describe "recovery codes" do
    setup do
      user = user_fixture()
      secret = MFA.new_totp_secret()
      {:ok, codes} = MFA.enable_totp(user, secret, code_for(secret))
      %{user: user, codes: codes}
    end

    test "each code works once, typed loosely", %{user: user, codes: [code | _]} do
      assert :ok = MFA.spend_recovery_code(user, String.upcase(code) <> " ")
      assert {:error, :invalid_code} = MFA.spend_recovery_code(user, code)
      assert MFA.recovery_codes_left(user) == 9
    end

    test "another account's code does not work", %{codes: [code | _]} do
      other = user_fixture()
      assert {:error, :invalid_code} = MFA.spend_recovery_code(other, code)
    end

    test "a new set replaces the old one", %{user: user, codes: [old | _]} do
      assert {:ok, new_codes} = MFA.regenerate_recovery_codes(user)
      assert {:error, :invalid_code} = MFA.spend_recovery_code(user, old)
      assert :ok = MFA.spend_recovery_code(user, hd(new_codes))
    end

    test "removing the last factor discards them", %{user: user, codes: [code | _]} do
      {:ok, _user} = MFA.disable_totp(user)

      refute MFA.mfa?(user)
      refute Repo.exists?(where(UserTOTP, user_id: ^user.id))
      assert MFA.recovery_codes_left(user) == 0
      assert {:error, :invalid_code} = MFA.spend_recovery_code(user, code)
      assert {:error, :no_mfa} = MFA.regenerate_recovery_codes(user)
    end
  end
end
