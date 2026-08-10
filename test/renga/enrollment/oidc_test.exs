defmodule Renga.Enrollment.OIDCTest do
  use ExUnit.Case, async: false

  alias Renga.Enrollment.{JWKSCache, OIDC}

  setup do
    JWKSCache.clear()
    Req.Test.set_req_test_to_shared(OIDC)
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    public = public_jwk(key, "key-#{System.unique_integer([:positive])}")
    nonce = :crypto.strong_rand_bytes(32)
    installation_key = :crypto.strong_rand_bytes(32)
    %{key: key, public: public, nonce: nonce, installation_key: installation_key}
  end

  test "verifies challenge-bound evidence into a provider-neutral envelope", f do
    token = token(f, claims(f))
    assert {:ok, verified} = OIDC.verify(config(f), token, f.nonce, f.installation_key)
    assert verified.replay_digest == nil
    assert verified.envelope["assurance"] == "oidc_challenge_bound"
    assert verified.envelope["subject"] == "subject-1"
    assert verified.envelope["verifier_key"]["d"] == nil
    refute inspect(verified.envelope) =~ token
  end

  test "explicit bearer-unbound evidence has lower assurance and replay digest", f do
    config = config(f, %{"binding_mode" => "bearer_unbound"})
    token = token(f, Map.drop(claims(f), ["nonce", "cnf"]))
    assert {:ok, verified} = OIDC.verify(config, token, f.nonce, f.installation_key)
    assert verified.envelope["assurance"] == "oidc_bearer_unbound"
    assert verified.replay_digest == :crypto.hash(:sha256, token)
  end

  test "rejects issuer mismatch", f do
    assert_invalid(f, Map.put(claims(f), "iss", "https://other.example"))
  end

  test "accepts string and singleton-list audience", f do
    assert {:ok, _} = verify(f, claims(f))
    assert {:ok, _} = verify(f, Map.put(claims(f), "aud", ["renga-agent"]))
  end

  test "multiple audiences require exact configured authorized party", f do
    claims = claims(f) |> Map.put("aud", ["other", "renga-agent"]) |> Map.put("azp", "client")
    assert {:ok, _} = verify(f, claims, %{"authorized_party" => "client"})
    assert_invalid(f, claims, %{"authorized_party" => "wrong"})
    assert_invalid(f, Map.delete(claims, "azp"), %{"authorized_party" => "client"})
  end

  test "rejects algorithms outside the allowlist and invalid algorithm configuration", f do
    assert {:error, :invalid_configuration} =
             OIDC.validate_configuration(config(f, %{"algorithms" => ["HS256"]}))

    assert {:error, :invalid_evidence} =
             OIDC.verify(config(f), "e30.e30.", f.nonce, f.installation_key)
  end

  test "enforces exp boundary with configured clock skew", f do
    now = now()
    assert_invalid(f, Map.put(claims(f), "exp", now - 1))

    within_skew =
      claims(f)
      |> Map.put("iat", now - 1)
      |> Map.put("nbf", now - 1)
      |> Map.put("exp", now)

    assert {:ok, _} = verify(f, within_skew, %{"clock_skew_seconds" => 1})
  end

  test "enforces nbf and iat future boundaries", f do
    now = now()
    assert_invalid(f, Map.put(claims(f), "nbf", now + 2))
    assert_invalid(f, Map.put(claims(f), "iat", now + 2))
    assert {:ok, _} = verify(f, Map.put(claims(f), "nbf", now + 1), %{"clock_skew_seconds" => 1})
  end

  test "enforces maximum token age and lifetime boundaries", f do
    now = now()
    assert_invalid(f, claims(f) |> Map.put("iat", now - 301) |> Map.put("nbf", now - 301))
    assert_invalid(f, claims(f) |> Map.put("iat", now) |> Map.put("exp", now + 601))

    assert {:ok, _} =
             verify(f, claims(f) |> Map.put("iat", now - 300) |> Map.put("nbf", now - 300))
  end

  test "requires configured claim path and exact type", f do
    required = [%{"path" => ["roles"], "type" => "string_list"}]

    assert {:ok, _} =
             verify(f, Map.put(claims(f), "roles", ["installer"]), %{
               "required_claims" => required
             })

    assert_invalid(f, Map.put(claims(f), "roles", "installer"), %{"required_claims" => required})
    assert_invalid(f, Map.delete(claims(f), "roles"), %{"required_claims" => required})
  end

  test "rejects wrong nonce and installation key thumbprint", f do
    assert_invalid(f, Map.put(claims(f), "nonce", "wrong"))
    assert_invalid(f, put_in(claims(f), ["cnf", "jkt"], "wrong"))
  end

  test "rejects unknown kid", f do
    other = %{f | public: Map.put(f.public, "kid", "other")}

    assert {:error, :invalid_evidence} =
             OIDC.verify(config(f), token(other, claims(f)), f.nonce, f.installation_key)
  end

  test "rejects private, malformed, and duplicate static JWKs", f do
    private =
      f.key |> JOSE.JWK.to_map() |> elem(1) |> Map.merge(%{"kid" => "private", "alg" => "EdDSA"})

    assert_config_invalid(config(f, %{"jwks" => [private]}))
    assert_config_invalid(config(f, %{"jwks" => [%{"kid" => "bad", "kty" => "OKP"}]}))
    assert_config_invalid(config(f, %{"jwks" => [Map.put(f.public, "x", "AA")]}))
    assert_config_invalid(config(f, %{"jwks" => [f.public, f.public]}))
  end

  test "configuration rejects wrong source options and authorized-party types", f do
    assert_config_invalid(config(f, %{"authorized_party" => 123}))
    assert_config_invalid(config(f, %{"http_timeout_ms" => 1_000}))

    assert_config_invalid(
      remote_config(f, %{"http_timeout_ms" => 0, "max_jwks_staleness_seconds" => 60})
    )
  end

  test "rejects malformed and oversized compact tokens without leaking them", f do
    assert {:error, :invalid_evidence} =
             OIDC.verify(config(f), "not.jwt", f.nonce, f.installation_key)

    huge = String.duplicate("x", 32_769)
    assert {:error, :invalid_evidence} = OIDC.verify(config(f), huge, f.nonce, f.installation_key)
  end

  test "JWKS cache hits and unknown kid performs exactly one refresh", f do
    url_config = remote_config(f)
    Req.Test.expect(OIDC, 2, fn conn -> Req.Test.json(conn, %{"keys" => [f.public]}) end)
    assert {:ok, _} = verify(f, claims(f), url_config)
    assert {:ok, _} = verify(f, claims(f), url_config)

    unknown = %{f | public: Map.put(f.public, "kid", "missing")}
    assert {:error, :invalid_evidence} = verify(unknown, claims(f), url_config)
  end

  test "JWKS redirect, non-200, malformed, and oversized responses are unavailable", f do
    for response <- [:redirect, :failure, :malformed, :oversized] do
      JWKSCache.clear()
      Req.Test.stub(OIDC, fn conn -> jwks_response(conn, response) end)
      assert {:error, :unavailable} = verify(f, claims(f), remote_config(f))
    end
  end

  test "JWKS last-known-good fallback is bounded by configured staleness", f do
    config = remote_config(f, %{"max_jwks_staleness_seconds" => 120})
    Req.Test.stub(OIDC, fn conn -> Req.Test.json(conn, %{"keys" => [f.public]}) end)
    assert {:ok, _} = verify(f, claims(f), config)

    [{url, keys, fetched}] = :ets.tab2list(JWKSCache)
    :ets.insert(JWKSCache, {url, keys, fetched - 61})
    Req.Test.stub(OIDC, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    assert {:ok, _} = verify(f, claims(f), config)

    :ets.insert(JWKSCache, {url, keys, fetched - 121})
    assert {:error, :unavailable} = verify(f, claims(f), config)
  end

  test "invalid forced refresh preserves the last-known-good public keys", f do
    config = remote_config(f, %{"max_jwks_staleness_seconds" => 120})
    Req.Test.stub(OIDC, fn conn -> Req.Test.json(conn, %{"keys" => [f.public]}) end)
    assert {:ok, _} = verify(f, claims(f), config)

    unknown = %{f | public: Map.put(f.public, "kid", "rotated")}
    private = f.key |> JOSE.JWK.to_map() |> elem(1)
    Req.Test.stub(OIDC, fn conn -> Req.Test.json(conn, %{"keys" => [private]}) end)

    assert {:error, :unavailable} = verify(unknown, claims(f), config)

    assert [{_, [cached], _}] =
             Enum.reject(:ets.tab2list(JWKSCache), &match?({{:forced_refresh, _}, _, _}, &1))

    assert cached["kid"] == f.public["kid"]
  end

  defp config(f, overrides \\ %{}) do
    Map.merge(
      %{
        "issuer" => "https://issuer.example",
        "audiences" => ["renga-agent"],
        "algorithms" => ["EdDSA"],
        "subject_claim" => ["sub"],
        "max_token_age_seconds" => 300,
        "max_token_lifetime_seconds" => 600,
        "clock_skew_seconds" => 0,
        "binding_mode" => "challenge_bound",
        "jwks" => [f.public]
      },
      overrides
    )
  end

  defp remote_config(f, overrides \\ %{}) do
    config(f, %{
      "jwks_url" => "http://issuer.example/jwks",
      "allow_insecure_http" => true,
      "http_timeout_ms" => 100,
      "max_jwks_staleness_seconds" => 0
    })
    |> Map.delete("jwks")
    |> Map.merge(overrides)
  end

  defp claims(f) do
    now = now()

    %{
      "iss" => "https://issuer.example",
      "aud" => "renga-agent",
      "sub" => "subject-1",
      "iat" => now,
      "nbf" => now,
      "exp" => now + 300,
      "nonce" => Base.url_encode64(f.nonce, padding: false),
      "cnf" => %{"jkt" => installation_thumbprint(f.installation_key)}
    }
  end

  defp token(f, claims) do
    f.key
    |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => f.public["kid"]}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp verify(f, claims, overrides \\ %{}) do
    config = if Map.has_key?(overrides, "jwks_url"), do: overrides, else: config(f, overrides)
    OIDC.verify(config, token(f, claims), f.nonce, f.installation_key)
  end

  defp assert_invalid(f, claims, overrides \\ %{}),
    do: assert({:error, :invalid_evidence} = verify(f, claims, overrides))

  defp assert_config_invalid(config),
    do: assert({:error, :invalid_configuration} = OIDC.validate_configuration(config))

  defp now, do: System.system_time(:second)

  defp installation_thumbprint(key),
    do:
      JOSE.JWK.thumbprint(
        JOSE.JWK.from_map(%{
          "kty" => "OKP",
          "crv" => "Ed25519",
          "x" => Base.url_encode64(key, padding: false)
        })
      )

  defp public_jwk(key, kid),
    do:
      key
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => kid, "alg" => "EdDSA"})

  defp jwks_response(conn, :redirect),
    do:
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example")
      |> Plug.Conn.send_resp(302, "")

  defp jwks_response(conn, :failure), do: Plug.Conn.send_resp(conn, 503, "down")
  defp jwks_response(conn, :malformed), do: Req.Test.json(conn, %{"keys" => "bad"})

  defp jwks_response(conn, :oversized),
    do:
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"keys" => [String.duplicate("x", 262_145)]}))
end
