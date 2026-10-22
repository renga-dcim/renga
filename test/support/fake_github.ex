defmodule Renga.FakeGitHub do
  @moduledoc """
  GitHub's OAuth and user APIs for tests, through the same `Req.Test` stub
  as `Renga.FakeOIDCProvider`. It checks the client secret, the redirect
  URI, and the PKCE verifier on the code exchange.

      FakeGitHub.stub()
      params = FakeGitHub.authorize(url, %{"id" => 123, "login" => "sam"}, emails)
  """

  @stub Renga.Accounts.OIDC

  @doc "Routes Renga's provider requests in this test process to the fake."
  def stub(opts \\ []) do
    secret = Keyword.get(opts, :client_secret, "client-secret")
    Req.Test.stub(@stub, fn conn -> handle(conn, secret) end)
  end

  @doc """
  Plays GitHub's side of the authorization URL: approves it as `user`, with
  `emails` as the `/user/emails` answer, and returns the callback
  parameters. `emails` may be `:forbidden` for a token without the scope.
  """
  def authorize(url, user, emails \\ []) do
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    code = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    token = "gho_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    Process.put({__MODULE__, code}, %{
      token: token,
      client_id: query["client_id"],
      challenge: query["code_challenge"],
      redirect_uri: query["redirect_uri"]
    })

    Process.put({__MODULE__, token}, %{user: user, emails: emails})

    %{"code" => code, "state" => query["state"]}
  end

  defp handle(conn, secret) do
    case {conn.method, conn.host, conn.request_path} do
      {"POST", "github.com", "/login/oauth/access_token"} -> token(conn, secret)
      {"GET", "api.github.com", "/user"} -> api(conn, :user)
      {"GET", "api.github.com", "/user/emails"} -> api(conn, :emails)
      _other -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp token(conn, secret) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    grant = Process.delete({__MODULE__, params["code"]})

    if grant && params["client_secret"] == secret && params["client_id"] == grant.client_id &&
         params["redirect_uri"] == grant.redirect_uri && pkce_ok?(grant, params) do
      json(conn, 200, %{"access_token" => grant.token, "token_type" => "bearer"})
    else
      # GitHub reports a refused exchange with a 200.
      json(conn, 200, %{"error" => "bad_verification_code"})
    end
  end

  defp api(conn, key) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         %{} = account <- Process.get({__MODULE__, token}) do
      case Map.fetch!(account, key) do
        :forbidden -> json(conn, 403, %{"message" => "Resource not accessible"})
        body -> json(conn, 200, body)
      end
    else
      _ -> json(conn, 401, %{"message" => "Bad credentials"})
    end
  end

  defp pkce_ok?(%{challenge: challenge}, %{"code_verifier" => verifier})
       when is_binary(challenge),
       do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

  defp pkce_ok?(_grant, _params), do: false

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
