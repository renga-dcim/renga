defmodule Renga.Accounts.SecurityNoticeDeliveryTest do
  # Swaps the application's mailer, so it runs alone.
  use Renga.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Renga.AccountsFixtures

  alias Renga.Accounts

  # Fixtures send their own email, so the mailer fails only afterwards.
  setup do
    user = user_fixture()
    totp_fixture(user)
    mailer_config = Application.fetch_env!(:renga, Renga.Mailer)
    on_exit(fn -> Application.put_env(:renga, Renga.Mailer, mailer_config) end)
    Application.put_env(:renga, Renga.Mailer, adapter: Renga.FailingMailerAdapter)
    %{user: user}
  end

  test "an undelivered notice is logged and reported, and the change stands", %{user: user} do
    log =
      capture_log(fn ->
        assert {:ok, _user, {:error, :unavailable}} =
                 Accounts.remove_mfa_by_operator(user.email, "Jane (ticket 12)")
      end)

    assert log =~ "mfa_removed_by_operator could not be sent"
    refute Accounts.mfa?(user)
  end

  test "the release command tells the operator the notice was not sent", %{user: user} do
    stderr =
      capture_io(:stderr, fn ->
        capture_log(fn ->
          capture_io(fn -> assert :ok = Renga.Release.remove_mfa(user.email, "Jane") end)
        end)
      end)

    assert stderr =~ "The notice could not be emailed"
    refute Accounts.mfa?(user)
  end
end
