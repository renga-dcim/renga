defmodule Renga.Accounts.SecurityLogTest do
  use Renga.DataCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Swoosh.TestAssertions

  alias Renga.Accounts
  alias Renga.Accounts.MFA
  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.SecurityLog
  alias Renga.FakeAuthenticator
  alias Renga.Repo

  defp kinds(user), do: user |> SecurityLog.list() |> Enum.map(& &1.kind)

  defp rechecked_token(user) do
    token = Accounts.generate_user_session_token(user)
    :ok = Accounts.recheck_with_password(user, token, valid_user_password())
    token
  end

  # Fixtures send confirmation and password emails of their own.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp notice_to(email) do
    assert_received {:email,
                     %{subject: "Security notice from Renga", to: [{_, ^email}], text_body: body}}

    body
  end

  describe "record/3 and describe/1" do
    test "lists events with readable lines" do
      user = user_fixture()
      Accounts.record_sign_in(user, "passkey")
      SecurityLog.record(user, "mfa_removed_by_operator", %{"actor" => "Jane (ticket 12)"})

      lines =
        user |> Accounts.list_security_events() |> Enum.map(&Accounts.describe_security_event/1)

      assert Enum.sort(lines) == [
               "Second factors removed by an operator (Jane (ticket 12))",
               "Signed in with a passkey"
             ]
    end

    test "rejects an unknown kind" do
      user = user_fixture()
      assert_raise FunctionClauseError, fn -> SecurityLog.record(user, "made_up") end
    end

    test "keeps each account's events apart" do
      user = user_fixture()
      Accounts.record_sign_in(user, "password")

      assert kinds(user) == ["signed_in"]
      assert kinds(user_fixture()) == []
    end
  end

  describe "notices" do
    test "adding and removing an authenticator app emails the account" do
      user = set_password(user_fixture())
      token = rechecked_token(user)
      flush_emails()
      secret = MFA.new_totp_secret()

      {:ok, [_ | _]} =
        Accounts.add_totp(user, token, secret, NimbleTOTP.verification_code(secret))

      assert notice_to(user.email) =~ "An authenticator app was added"
      # The first factor brings the first recovery codes, which are logged too.
      assert notice_to(user.email) =~ "New recovery codes were generated"
      assert "recovery_codes_generated" in kinds(user)

      {:ok, _user} = Accounts.remove_totp(user, token)
      assert notice_to(user.email) =~ "The authenticator app was removed"
    end

    test "adding and removing a passkey emails the account" do
      user = set_password(user_fixture())
      token = rechecked_token(user)
      flush_emails()
      authenticator = FakeAuthenticator.new()
      response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))

      {:ok, passkey, [_ | _]} = Accounts.add_passkey(user, token, response, "Laptop")
      assert notice_to(user.email) =~ "A passkey was added"
      assert notice_to(user.email) =~ "New recovery codes were generated"

      # A second factor brings no new codes, so neither a notice nor an entry.
      second =
        FakeAuthenticator.register(FakeAuthenticator.new(), Passkeys.registration_options(user))

      {:ok, _second, nil} = Accounts.add_passkey(user, token, second, "Phone")
      assert notice_to(user.email) =~ "A passkey was added"
      assert Enum.count(kinds(user), &(&1 == "recovery_codes_generated")) == 1

      {:ok, _passkey} = Accounts.remove_passkey(user, token, passkey.id)
      assert notice_to(user.email) =~ "A passkey was removed"
    end

    test "new recovery codes and a spent one email the account" do
      user = set_password(user_fixture())
      {secret, _codes} = totp_fixture(user)
      flush_emails()
      token = Accounts.generate_user_session_token(user)
      :ok = Accounts.recheck_with_totp(user, token, NimbleTOTP.verification_code(secret))

      {:ok, [code | _]} = Accounts.regenerate_recovery_codes(user, token)
      assert notice_to(user.email) =~ "New recovery codes were generated"

      assert {:ok, :recovery_code} = Accounts.verify_second_step(user, code)
      assert notice_to(user.email) =~ "A recovery code was used"
      assert "recovery_code_used" in kinds(user)
    end

    test "a password change is logged and emailed" do
      user = user_fixture()
      flush_emails()
      {:ok, _} = Accounts.update_user_password(user, %{password: valid_user_password()})

      assert notice_to(user.email) =~ "The password of your Renga account was changed"
      assert "password_changed" in kinds(user)
    end

    test "an email change notifies the new and the old address" do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      flush_emails()
      {:ok, _user} = Accounts.update_user_email(user, token)

      assert notice_to(email) =~ "The email address of your Renga account was changed"
      assert notice_to(user.email) =~ "The email address of your Renga account was changed"
      assert kinds(user) == ["email_changed"]
    end

    test "a failed change sends nothing" do
      user = user_fixture()
      {secret, _codes} = totp_fixture(user)
      flush_emails()
      assert {:error, _} = Accounts.update_user_email(user, "oops")
      assert {:error, :invalid_code} = Accounts.verify_second_step(user, wrong_totp_code(secret))

      assert_no_email_sent()
    end

    test "sign-ins are logged without a notice" do
      user = user_fixture()
      flush_emails()
      Accounts.record_sign_in(user, "magic_link")

      assert_no_email_sent()
    end
  end

  describe "notices go to the stored address" do
    test "not to an outdated copy of the account" do
      user = set_password(user_fixture())
      token = rechecked_token(user)
      current = unique_user_email()
      Repo.update_all(where(Accounts.User, id: ^user.id), set: [email: current])
      flush_emails()

      response =
        FakeAuthenticator.register(FakeAuthenticator.new(), Passkeys.registration_options(user))

      {:ok, _passkey, _codes} = Accounts.add_passkey(user, token, response, "Laptop")

      assert notice_to(current) =~ "A passkey was added"
      old_email = user.email
      refute_received {:email, %{to: [{_, ^old_email}]}}
    end
  end

  describe "a fresh sign-in" do
    test "is logged only with the session it creates" do
      user = user_fixture()

      assert_raise Ecto.ChangeError, fn ->
        Accounts.create_signed_in_session(user, "not a browser session", "password")
      end

      assert kinds(user) == []

      assert {:ok, token} =
               Accounts.create_signed_in_session(user, Ecto.UUID.generate(), "password")

      assert Accounts.get_user_by_session_token(token)
      assert kinds(user) == ["signed_in"]
    end
  end

  describe "sign-ins after a second step" do
    test "are logged once, with the session they create" do
      user = user_fixture()
      totp_fixture(user)
      pending = Accounts.create_pending_second_step(user)

      assert {:ok, _session} = Accounts.finish_pending_second_step(user, pending, nil, :totp)
      assert :error = Accounts.finish_pending_second_step(user, pending, nil, :totp)

      assert [%{metadata: %{"method" => "totp"}}] =
               user |> SecurityLog.list() |> Enum.filter(&(&1.kind == "signed_in"))
    end
  end

  describe "remove_mfa_by_operator/2" do
    test "removes every factor and code and names the operator" do
      user = set_password(user_fixture())
      token = rechecked_token(user)
      authenticator = FakeAuthenticator.new()
      response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))
      {:ok, _passkey, _codes} = Accounts.add_passkey(user, token, response, "Laptop")
      totp_fixture(user)

      flush_emails()
      assert {:ok, _user, :ok} = Accounts.remove_mfa_by_operator(user.email, "Jane (ticket 12)")
      assert notice_to(user.email) =~ "An operator removed every passkey"

      refute Accounts.mfa?(user)
      refute Passkeys.any?(user)
      assert MFA.recovery_codes_left(user) == 0

      # Events from one millisecond have no order, so look for it.
      assert Enum.any?(
               SecurityLog.list(user),
               &match?(
                 %{kind: "mfa_removed_by_operator", metadata: %{"actor" => "Jane (ticket 12)"}},
                 &1
               )
             )
    end

    test "the release command removes them and emails the account" do
      user = user_fixture()
      totp_fixture(user)
      flush_emails()

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Renga.Release.remove_mfa(user.email, "Jane (ticket 12)")
      end)

      refute Accounts.mfa?(user)
      assert notice_to(user.email) =~ "An operator removed every passkey"
    end

    test "an unknown email changes nothing" do
      assert {:error, :not_found} = Accounts.remove_mfa_by_operator("nobody@example.com", "Jane")
    end
  end
end
