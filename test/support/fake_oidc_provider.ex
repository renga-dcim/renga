defmodule Renga.FakeOIDCProvider do
  @moduledoc """
  An OpenID Connect provider for tests. It answers discovery, signing-key,
  and token requests through a `Req.Test` stub, signs ID tokens with an ES256
  key, and checks the PKCE verifier against the authorization request.

      fake = FakeOIDCProvider.new()
      FakeOIDCProvider.stub(fake)
      # ...send the browser to the authorization URL, then:
      params = FakeOIDCProvider.authorize(fake, url, %{"sub" => "123", "email" => "a@b.c"})
  """

  defstruct [:issuer, :jwk, :kid, client_id: "renga", discovery: %{}, id_token: true]

  @stub Renga.Accounts.OIDC

  def new(opts \\ []) do
    %__MODULE__{
      issuer:
        Keyword.get(
          opts,
          :issuer,
          "https://idp-#{System.unique_integer([:positive])}.example.com"
        ),
      jwk: JOSE.JWK.generate_key({:ec, "P-256"}),
      kid: "key-#{System.unique_integer([:positive])}",
      client_id: Keyword.get(opts, :client_id, "renga"),
      # Overrides for the discovery document, and whether tokens carry an
      # ID token, for providers that misbehave.
      discovery: Keyword.get(opts, :discovery, %{}),
      id_token: Keyword.get(opts, :id_token, true)
    }
  end

  @doc "Routes Renga's provider requests in this test process to `fake`."
  def stub(%__MODULE__{} = fake) do
    Req.Test.stub(@stub, fn conn -> handle(fake, conn) end)
  end

  @doc """
  Plays the provider's side of the authorization URL: approves the request
  with `claims` in the ID token and returns the callback parameters. Options
  may change the token: `:nonce`, `:aud`, `:iss`, `:exp`, and `:jwk` and
  `:kid` to sign with another key.
  """
  def authorize(%__MODULE__{} = fake, url, claims, opts \\ []) do
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    code = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => Keyword.get(opts, :iss, fake.issuer),
          "aud" => Keyword.get(opts, :aud, fake.client_id),
          "iat" => now,
          "exp" => Keyword.get(opts, :exp, now + 300),
          "nonce" => Keyword.get(opts, :nonce, query["nonce"])
        },
        claims
      )

    Process.put({__MODULE__, code}, %{
      claims: claims,
      challenge: query["code_challenge"],
      redirect_uri: query["redirect_uri"],
      jwk: Keyword.get(opts, :jwk, fake.jwk),
      kid: Keyword.get(opts, :kid, fake.kid)
    })

    %{"code" => code, "state" => query["state"], "iss" => fake.issuer}
  end

  defp handle(fake, conn) do
    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/openid-configuration"} -> json(conn, discovery(fake))
      {"GET", "/jwks"} -> json(conn, %{"keys" => [public_jwk(fake)]})
      {"POST", "/token"} -> token(fake, conn)
      _other -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp discovery(fake) do
    %{
      "issuer" => fake.issuer,
      "authorization_endpoint" => fake.issuer <> "/authorize",
      "token_endpoint" => fake.issuer <> "/token",
      "userinfo_endpoint" => fake.issuer <> "/userinfo",
      "jwks_uri" => fake.issuer <> "/jwks",
      "response_types_supported" => ["code"],
      "scopes_supported" => ["openid", "email", "profile", "groups"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["ES256"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
    }
    |> Map.merge(fake.discovery)
  end

  defp public_jwk(fake) do
    {_fields, map} = fake.jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.merge(map, %{"kid" => fake.kid, "use" => "sig", "alg" => "ES256"})
  end

  defp token(fake, conn) do
    send(self(), {__MODULE__, :token_requested})

    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    grant = Process.delete({__MODULE__, params["code"]})

    if grant && pkce_ok?(grant, params) && grant.redirect_uri == params["redirect_uri"] do
      id_token =
        grant.jwk
        |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => grant.kid}, grant.claims)
        |> JOSE.JWS.compact()
        |> elem(1)

      body = %{"access_token" => "access", "token_type" => "Bearer", "expires_in" => 300}
      json(conn, if(fake.id_token, do: Map.put(body, "id_token", id_token), else: body))
    else
      conn |> Plug.Conn.put_status(400) |> json(%{"error" => "invalid_grant"})
    end
  end

  defp pkce_ok?(%{challenge: challenge}, %{"code_verifier" => verifier})
       when is_binary(challenge),
       do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

  defp pkce_ok?(_grant, _params), do: false

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(conn.status || 200, Jason.encode!(body))
  end
end
