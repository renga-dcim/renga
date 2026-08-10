defmodule RengaWeb.Api.V1.EnrollmentController do
  use RengaWeb, :controller

  alias Renga.Enrollment

  def challenge(conn, params) do
    with {:ok, org} <- string(params, "organization", 1, 63),
         {:ok, profile} <- string(params, "profile", 1, 255),
         {:ok, installation} <- string(params, "installation_id", 36, 36),
         {:ok, _} <- Ecto.UUID.cast(installation),
         {:ok, encoded_key} <- string(params, "public_key", 43, 44),
         {:ok, key} <- decode(encoded_key, 32),
         {:ok, result} <- Enrollment.create_challenge(org, profile, installation, key) do
      json(conn, %{
        challenge_id: result.id,
        nonce: result.nonce,
        expires_at: DateTime.to_iso8601(result.expires_at),
        proof: %{
          version: result.transcript_version,
          algorithm: "Ed25519",
          canonicalization: "renga-canonical-v1"
        }
      })
    else
      _ -> safe_error(conn, :not_found, "enrollment_not_available")
    end
  end

  def attempt(conn, params) do
    with {:ok, challenge_id} <- string(params, "challenge_id", 36, 36),
         {:ok, _} <- Ecto.UUID.cast(challenge_id),
         {:ok, nonce64} <- string(params, "nonce", 43, 44),
         {:ok, nonce} <- decode(nonce64, 32),
         {:ok, evidence} <- evidence(params["evidence"]),
         requested when is_list(requested) and length(requested) <= 64 <-
           Map.get(params, "requested_capabilities", []),
         true <- Enum.all?(requested, &(is_binary(&1) and byte_size(&1) <= 255)),
         metadata when is_map(metadata) and map_size(metadata) <= 64 <-
           Map.get(params, "metadata", %{}),
         true <- byte_size(Jason.encode!(metadata)) <= 16_000,
         {:ok, proof64} <- string(params, "proof", 86, 88),
         {:ok, proof} <- decode(proof64, 64),
         {:ok, result} <-
           Enrollment.submit_attempt(challenge_id, nonce, evidence, requested, metadata, proof) do
      json(conn, result)
    else
      {:error, :submission_conflict} ->
        safe_error(conn, :conflict, "submission_conflict")

      {:error, reason} when reason in [:invalid_proof, :invalid_request, :invalid_evidence] ->
        safe_error(conn, :unprocessable_entity, "enrollment_denied")

      {:error, :unavailable} ->
        safe_error(conn, :service_unavailable, "verifier_unavailable")

      _ ->
        safe_error(conn, :not_found, "enrollment_not_available")
    end
  end

  defp evidence(%{"kind" => "manual"} = evidence) when map_size(evidence) == 3 do
    with {:ok, _} <- string(evidence, "public_id", 22, 128),
         {:ok, _} <- string(evidence, "secret", 32, 128),
         do: {:ok, evidence}
  end

  defp evidence(%{"kind" => "oidc", "token" => token} = evidence)
       when map_size(evidence) == 2 and is_binary(token) and byte_size(token) <= 32_768,
       do: {:ok, evidence}

  defp evidence(_), do: :error

  defp string(map, key, min, max) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) >= min and byte_size(value) <= max ->
        {:ok, value}

      _ ->
        :error
    end
  end

  defp decode(value, size) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == size -> {:ok, decoded}
      _ -> :error
    end
  end

  defp safe_error(conn, status, code),
    do: conn |> put_status(status) |> json(%{status: "denied", error: code})
end
