defmodule Renga.Enrollment.OIDC do
  @moduledoc "Fail-closed verification for an immutable, explicitly configured OIDC trust boundary."

  @algorithms ~w(RS256 EdDSA)
  @max_token_bytes 32_768
  @max_claim_bytes 65_536
  @max_keys 32
  @private_jwk_fields ~w(d p q dp dq qi oth k)

  @type verified :: %{envelope: map(), evidence_digest: binary(), replay_digest: binary() | nil}

  def validate_configuration(config) when is_map(config) do
    with :ok <- exact_keys(config),
         :ok <- issuer(config["issuer"]),
         :ok <- audiences(config["audiences"]),
         :ok <- algorithms(config["algorithms"]),
         :ok <- subject(config["subject_claim"]),
         :ok <- timing(config),
         :ok <- optional_configuration(config),
         :ok <- binding_configuration(config),
         :ok <- jwks_source(config) do
      :ok
    end
  end

  def validate_configuration(_), do: {:error, :invalid_configuration}

  def verify(config, token, nonce, installation_public_key)
      when is_binary(token) and is_binary(nonce) and is_binary(installation_public_key) do
    with :ok <- validate_configuration(config),
         true <- byte_size(token) <= @max_token_bytes,
         [_, _, _] <- String.split(token, "."),
         {:ok, header} <- decode_segment(token, 0),
         true <- is_binary(header["kid"]) and byte_size(header["kid"]) <= 255,
         true <- header["alg"] in config["algorithms"] and header["alg"] in @algorithms,
         {:ok, jwk} <- verification_key(config, header),
         {:ok, jwt} <- verify_signature(jwk, config["algorithms"], token),
         claims when is_map(claims) <- jwt.fields,
         true <- byte_size(Jason.encode!(claims)) <= @max_claim_bytes,
         :ok <- validate_claims(config, claims),
         :ok <- validate_binding(config, claims, nonce, installation_public_key),
         {:ok, envelope} <- envelope(config, claims, jwk, header),
         digest = :crypto.hash(:sha256, token) do
      {:ok,
       %{
         envelope: envelope,
         evidence_digest: digest,
         replay_digest: if(config["binding_mode"] == "bearer_unbound", do: digest)
       }}
    else
      {:error, :unavailable} = error -> error
      _ -> {:error, :invalid_evidence}
    end
  end

  def verify(_, _, _, _), do: {:error, :invalid_evidence}

  defp exact_keys(config) do
    required =
      ~w(issuer audiences algorithms subject_claim max_token_age_seconds max_token_lifetime_seconds clock_skew_seconds binding_mode)

    optional =
      ~w(authorized_party required_claims jwks jwks_url allow_insecure_http http_timeout_ms max_jwks_staleness_seconds)

    if Enum.all?(required, &Map.has_key?(config, &1)) and
         Enum.all?(Map.keys(config), &(&1 in (required ++ optional))) and
         valid_required_claims?(Map.get(config, "required_claims", [])),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp issuer(value) when is_binary(value) and byte_size(value) <= 255,
    do: Renga.Enrollment.SafeURL.validate(value, false)

  defp issuer(_), do: {:error, :invalid_configuration}

  defp audiences(v) when is_list(v) and v != [] and length(v) <= 16,
    do:
      if(Enum.all?(v, &(is_binary(&1) and &1 != "")),
        do: :ok,
        else: {:error, :invalid_configuration}
      )

  defp audiences(_), do: {:error, :invalid_configuration}

  defp algorithms(v) when is_list(v) and v != [],
    do: if(Enum.all?(v, &(&1 in @algorithms)), do: :ok, else: {:error, :invalid_configuration})

  defp algorithms(_), do: {:error, :invalid_configuration}

  defp subject(v) when is_list(v) and v != [] and length(v) <= 8,
    do: if(Enum.all?(v, &is_binary/1), do: :ok, else: {:error, :invalid_configuration})

  defp subject(_), do: {:error, :invalid_configuration}

  defp timing(c) do
    age = c["max_token_age_seconds"]
    life = c["max_token_lifetime_seconds"]
    skew = c["clock_skew_seconds"]
    tighter? = c["binding_mode"] != "bearer_unbound" or age <= 300

    if is_integer(age) and age in 1..3600 and is_integer(life) and life in 1..86_400 and
         is_integer(skew) and skew in 0..120 and tighter?,
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp optional_configuration(config) do
    authorized_party = Map.get(config, "authorized_party")
    timeout = Map.get(config, "http_timeout_ms")
    static? = Map.has_key?(config, "jwks")

    valid_party? =
      is_nil(authorized_party) or
        (is_binary(authorized_party) and authorized_party != "" and
           byte_size(authorized_party) <= 255)

    valid_source_options? =
      if static? do
        is_nil(timeout) and not Map.has_key?(config, "allow_insecure_http") and
          not Map.has_key?(config, "max_jwks_staleness_seconds")
      else
        is_integer(timeout) and timeout in 100..5_000
      end

    if valid_party? and valid_source_options?, do: :ok, else: {:error, :invalid_configuration}
  end

  defp binding_configuration(%{"binding_mode" => mode})
       when mode in ~w(challenge_bound bearer_unbound),
       do: :ok

  defp binding_configuration(_), do: {:error, :invalid_configuration}

  defp jwks_source(%{"jwks" => keys} = c) when is_list(keys),
    do:
      if(not Map.has_key?(c, "jwks_url") and length(keys) in 1..@max_keys,
        do: validate_keys(keys),
        else: {:error, :invalid_configuration}
      )

  defp jwks_source(%{"jwks_url" => url} = c),
    do:
      if(
        not Map.has_key?(c, "jwks") and
          is_integer(c["max_jwks_staleness_seconds"]) and
          c["max_jwks_staleness_seconds"] in 0..86_400,
        do: Renga.Enrollment.SafeURL.validate(url, c["allow_insecure_http"] == true),
        else: {:error, :invalid_configuration}
      )

  defp jwks_source(_), do: {:error, :invalid_configuration}

  defp verification_key(%{"jwks" => keys}, header) do
    with {:ok, sanitized} <- sanitize_keys(keys), do: select_key(sanitized, header)
  end

  defp verification_key(%{"jwks_url" => _} = config, header) do
    with {:ok, keys, _fetched_at} <-
           Renga.Enrollment.JWKSCache.get(config, &sanitize_keys/1) do
      case select_key(keys, header) do
        {:ok, jwk} ->
          {:ok, jwk}

        {:error, :unknown_key} ->
          case Renga.Enrollment.JWKSCache.get(config, &sanitize_keys/1, true) do
            {:ok, refreshed, _} -> select_key(refreshed, header)
            {:error, :unavailable} = error -> error
          end
      end
    end
  end

  defp validate_keys(keys) do
    case sanitize_keys(keys) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp sanitize_keys(keys) when is_list(keys) and length(keys) in 1..@max_keys do
    with true <- Enum.all?(keys, &valid_key_metadata?/1),
         true <- unique_kids?(keys),
         {:ok, sanitized} <- sanitize_public_keys(keys) do
      {:ok, sanitized}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp sanitize_keys(_), do: {:error, :invalid_configuration}

  defp valid_key_metadata?(key) do
    is_map(key) and is_binary(key["kid"]) and key["kid"] != "" and
      key["kty"] in ~w(RSA OKP) and key["alg"] in [nil | @algorithms] and
      key["use"] in [nil, "sig"] and valid_key_ops?(key["key_ops"]) and
      Enum.all?(@private_jwk_fields, &(not Map.has_key?(key, &1))) and
      compatible_algorithm?(key)
  end

  defp valid_key_ops?(nil), do: true
  defp valid_key_ops?(operations), do: operations == ["verify"]

  defp compatible_algorithm?(%{"kty" => "RSA", "alg" => alg}), do: alg in [nil, "RS256"]

  defp compatible_algorithm?(%{"kty" => "OKP", "crv" => "Ed25519", "alg" => alg}),
    do: alg in [nil, "EdDSA"]

  defp compatible_algorithm?(_), do: false

  defp unique_kids?(keys) do
    kids = Enum.map(keys, & &1["kid"])
    length(kids) == length(Enum.uniq(kids))
  end

  defp sanitize_public_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, sanitized} ->
      case sanitize_public_key(key) do
        {:ok, public} -> {:cont, {:ok, [public | sanitized]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
      error -> error
    end
  end

  defp sanitize_public_key(%{"kty" => "OKP", "x" => x} = key) do
    with {:ok, decoded} when byte_size(decoded) == 32 <- Base.url_decode64(x, padding: false),
         {:ok, jwk} <- parse_jwk(key) do
      public_map(jwk, key)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp sanitize_public_key(%{"kty" => "RSA", "n" => n, "e" => e} = key) do
    with {:ok, modulus} when byte_size(modulus) >= 256 <- Base.url_decode64(n, padding: false),
         {:ok, exponent} <- Base.url_decode64(e, padding: false),
         value when value >= 65_537 and rem(value, 2) == 1 <- :binary.decode_unsigned(exponent),
         {:ok, jwk} <- parse_jwk(key) do
      public_map(jwk, key)
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp sanitize_public_key(_), do: {:error, :invalid_configuration}

  defp parse_jwk(key) do
    {:ok, JOSE.JWK.from_map(key)}
  rescue
    _error in [ArgumentError, FunctionClauseError] -> {:error, :invalid_configuration}
  catch
    :error, :badarg -> {:error, :invalid_configuration}
  end

  defp public_map(jwk, original) do
    {_meta, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {:ok, Map.merge(public, Map.take(original, ~w(kid alg use key_ops)))}
  end

  defp verify_signature(jwk, algorithms, token) do
    case JOSE.JWT.verify_strict(jwk, algorithms, token) do
      {true, jwt, _} -> {:ok, jwt}
      _ -> {:error, :invalid_evidence}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError] -> {:error, :invalid_evidence}
  catch
    :error, :badarg -> {:error, :invalid_evidence}
  end

  defp select_key(keys, %{"kid" => kid, "alg" => alg}) do
    case Enum.filter(keys, &(&1["kid"] == kid and &1["alg"] in [nil, alg])) do
      [key] -> {:ok, JOSE.JWK.from_map(key)}
      _ -> {:error, :unknown_key}
    end
  end

  defp decode_segment(token, index) do
    with segment when is_binary(segment) <- Enum.at(String.split(token, "."), index),
         {:ok, raw} <- Base.url_decode64(segment, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(raw),
         do: {:ok, map},
         else: (_ -> {:error, :malformed})
  end

  defp validate_claims(c, claims) do
    now = DateTime.to_unix(Renga.Time.utc_now_ms())
    skew = c["clock_skew_seconds"]

    with iss when is_binary(iss) <- claims["iss"],
         true <- iss == c["issuer"],
         aud <- claims["aud"],
         true <- valid_audience?(aud, claims["azp"], c),
         exp when is_integer(exp) <- claims["exp"],
         nbf when is_integer(nbf) <- claims["nbf"],
         iat when is_integer(iat) <- claims["iat"],
         true <- exp > now - skew and nbf <= now + skew and iat <= now + skew,
         true <- iat < exp and nbf < exp,
         true <- now - iat <= c["max_token_age_seconds"] + skew,
         true <- exp - iat <= c["max_token_lifetime_seconds"],
         subject when is_binary(subject) and subject != "" and byte_size(subject) <= 255 <-
           claim_at(claims, c["subject_claim"]),
         :ok <- validate_required_claims(claims, Map.get(c, "required_claims", [])) do
      :ok
    else
      _ -> {:error, :invalid_claims}
    end
  end

  defp valid_audience?(aud, azp, c) when is_binary(aud) do
    aud in c["audiences"] and
      (is_nil(c["authorized_party"]) or
         (is_binary(azp) and azp == c["authorized_party"]))
  end

  defp valid_audience?(aud, azp, c) when is_list(aud) and length(aud) > 1 do
    Enum.all?(aud, &is_binary/1) and Enum.any?(aud, &(&1 in c["audiences"])) and
      is_binary(c["authorized_party"]) and azp == c["authorized_party"]
  end

  defp valid_audience?([aud], azp, c), do: valid_audience?(aud, azp, c)
  defp valid_audience?(_, _, _), do: false

  defp valid_required_claims?(claims) when is_list(claims) and length(claims) <= 32 do
    Enum.all?(claims, fn
      %{"path" => path, "type" => type} = requirement when map_size(requirement) == 2 ->
        is_list(path) and path != [] and length(path) <= 8 and Enum.all?(path, &is_binary/1) and
          type in ~w(string integer boolean string_list)

      _ ->
        false
    end)
  end

  defp valid_required_claims?(_), do: false

  defp validate_required_claims(claims, requirements) do
    if Enum.all?(requirements, fn requirement ->
         required_type?(claim_at(claims, requirement["path"]), requirement["type"])
       end),
       do: :ok,
       else: {:error, :invalid_claims}
  end

  defp required_type?(value, "string"), do: is_binary(value)
  defp required_type?(value, "integer"), do: is_integer(value)
  defp required_type?(value, "boolean"), do: is_boolean(value)

  defp required_type?(value, "string_list"),
    do: is_list(value) and length(value) <= 128 and Enum.all?(value, &is_binary/1)

  defp required_type?(_, _), do: false

  defp validate_binding(%{"binding_mode" => "bearer_unbound"}, _claims, _nonce, _key), do: :ok

  defp validate_binding(_c, claims, nonce, key) do
    expected_nonce = Base.url_encode64(nonce, padding: false)

    installation_jwk =
      JOSE.JWK.from_map(%{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "x" => Base.url_encode64(key, padding: false)
      })

    expected_jkt = JOSE.JWK.thumbprint(installation_jwk)

    if claims["nonce"] == expected_nonce and claim_at(claims, ["cnf", "jkt"]) == expected_jkt,
      do: :ok,
      else: {:error, :binding}
  end

  defp envelope(c, claims, jwk, header) do
    {_meta, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    thumbprint = JOSE.JWK.thumbprint(jwk)

    {:ok,
     %{
       "issuer" => claims["iss"],
       "subject" => claim_at(claims, c["subject_claim"]),
       "issued_at" => claims["iat"],
       "expires_at" => claims["exp"],
       "assurance" =>
         if(c["binding_mode"] == "challenge_bound",
           do: "oidc_challenge_bound",
           else: "oidc_bearer_unbound"
         ),
       "provenance" => %{"kind" => "oidc", "verified" => true, "claims" => claims},
       "claims" => claims,
       "verifier_key" => public,
       "verifier_key_thumbprint" => thumbprint,
       "kid" => header["kid"]
     }}
  end

  defp claim_at(value, []), do: value

  defp claim_at(map, [key | rest]) when is_map(map) and is_binary(key),
    do: claim_at(Map.get(map, key), rest)

  defp claim_at(_value, _path), do: nil
end
