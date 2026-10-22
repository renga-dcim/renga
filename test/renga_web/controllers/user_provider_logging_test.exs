defmodule RengaWeb.UserProviderLoggingTest do
  # Raises the application's log level to see failed sign-ins, logged at
  # info, so it runs alone.
  use RengaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Renga.AccountsFixtures

  alias Renga.FakeOIDCProvider

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)
    %{fake: fake}
  end

  test "a failed callback logs the reason and no attempt secret", %{conn: conn, fake: fake} do
    provider = identity_provider_fixture(fake)
    other = identity_provider_fixture(fake)
    conn = get(conn, ~p"/users/log-in/provider/#{provider.id}")
    attempt = get_session(conn, :provider_attempt)

    params =
      FakeOIDCProvider.authorize(fake, redirected_to(conn, 302), %{
        "sub" => "subject-1",
        "email" => "sam@example.com",
        "email_verified" => true
      })

    log = capture_log(fn -> get(recycle(conn), ~p"/users/auth/#{other.id}/callback", params) end)

    assert log =~ "failed: no_attempt"
    for secret <- ~w(state nonce verifier), do: refute(log =~ attempt[secret])
  end
end
