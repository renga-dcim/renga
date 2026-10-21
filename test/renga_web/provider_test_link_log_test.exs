defmodule RengaWeb.ProviderTestLinkLogTest do
  # Not async: the test lowers the global logger level, since the endpoint's
  # request log is what would leak the link's token.
  use RengaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Renga.AccountsFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.FakeOIDCProvider

  setup do
    fake = FakeOIDCProvider.new()
    FakeOIDCProvider.stub(fake)

    {:ok, {provider, _}} =
      IdentityProviders.create(
        %{
          "id" => "log-idp-#{System.unique_integer([:positive])}",
          "kind" => "oidc",
          "issuer" => fake.issuer,
          "display_name" => "New SSO",
          "client_id" => fake.client_id,
          "client_secret" => "client-secret"
        },
        {:operator, "release"}
      )

    {:ok, {token, _}} = IdentityProviders.create_test(provider, {:operator, "release"})

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    %{token: token, user: user_fixture()}
  end

  test "a test link's token is never logged, even for a request turned away before it is used",
       %{conn: conn, token: token} do
    log =
      capture_log([level: :debug], fn ->
        for path <- [
              "/users/providers/test/#{token}",
              "/users/%70roviders/test/#{token}",
              "/%75sers/providers/%74est/#{token}"
            ] do
          assert_raise Phoenix.NotAcceptableError, fn ->
            conn
            |> put_req_header("accept", "application/json")
            |> get(path)
          end
        end

        # The rejected requests did not spend the link.
        conn = get(build_conn(), ~p"/users/providers/test/#{token}")
        assert redirected_to(conn, 302) =~ "/authorize"
      end)

    refute log =~ token
    refute log =~ "/test/"

    # Other requests are still logged.
    assert capture_log([level: :debug], fn -> get(build_conn(), ~p"/users/log-in") end) =~
             "GET /users/log-in"
  end
end
