defmodule Renga.FakeAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests: an ES256 key pair that
  answers `navigator.credentials.create()` and `.get()` options the way a
  browser would, with base64url-encoded fields.
  """

  defstruct [
    :credential_id,
    :private_key,
    :public_point,
    :user_handle,
    sign_count: 0,
    user_verified: true,
    alg: -7,
    attested: true,
    client_data: %{}
  ]

  @doc "A new authenticator holding one credential."
  def new(opts \\ []) do
    {public_point, private_key} = :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(32),
      private_key: private_key,
      public_point: public_point,
      sign_count: Keyword.get(opts, :sign_count, 0),
      user_verified: Keyword.get(opts, :user_verified, true),
      alg: Keyword.get(opts, :alg, -7),
      user_handle: Keyword.get(opts, :user_handle),
      attested: Keyword.get(opts, :attested, true),
      client_data: Keyword.get(opts, :client_data, %{})
    }
  end

  @doc "The response to registration options, as the browser hook sends it."
  def register(%__MODULE__{} = authenticator, options, origin \\ origin()) do
    client_data = client_data(authenticator, "webauthn.create", options.challenge, origin)
    <<4, x::binary-size(32), y::binary-size(32)>> = authenticator.public_point

    # Like a real authenticator, remember which account the credential was
    # created for, and return its handle in assertions.
    Process.put({__MODULE__, authenticator.credential_id}, options.user.id)

    cose_key =
      %{
        1 => 2,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: x},
        -3 => %CBOR.Tag{tag: :bytes, value: y}
      }
      |> then(&if(authenticator.alg, do: Map.put(&1, 3, authenticator.alg), else: &1))
      |> CBOR.encode()

    attested =
      <<0::128, byte_size(authenticator.credential_id)::16>> <>
        authenticator.credential_id <> cose_key

    # `attested: false` leaves out the credential, as a broken
    # authenticator might, with the attested-data flag cleared.
    auth_data =
      if authenticator.attested,
        do: auth_data(authenticator, options.rp.id, 0x40) <> attested,
        else: auth_data(authenticator, options.rp.id, 0)

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      "rawId" => encode(authenticator.credential_id),
      "clientDataJSON" => encode(client_data),
      "attestationObject" => encode(attestation_object),
      "transports" => ["internal"]
    }
  end

  @doc "The response to authentication options, as the browser hook sends it."
  def assert(%__MODULE__{} = authenticator, options, origin \\ origin()) do
    client_data = client_data(authenticator, "webauthn.get", options.challenge, origin)
    auth_data = auth_data(authenticator, options.rpId, 0)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [authenticator.private_key, :secp256r1]
      )

    %{
      "rawId" => encode(authenticator.credential_id),
      "authenticatorData" => encode(auth_data),
      "signature" => encode(signature),
      "clientDataJSON" => encode(client_data),
      "userHandle" => user_handle(authenticator)
    }
  end

  # `user_handle: :omit` sends none, a binary sends that handle (already
  # base64url), and otherwise the handle the credential was created for.
  defp user_handle(%{user_handle: :omit}), do: nil
  defp user_handle(%{user_handle: handle}) when is_binary(handle), do: handle

  defp user_handle(authenticator),
    do: Process.get({__MODULE__, authenticator.credential_id})

  defp auth_data(authenticator, rp_id, extra_flags) do
    import Bitwise
    # User present, plus user verified unless the test turns it off.
    flags = 0x01 ||| if(authenticator.user_verified, do: 0x04, else: 0) ||| extra_flags
    :crypto.hash(:sha256, rp_id) <> <<flags, authenticator.sign_count::32>>
  end

  # `client_data:` adds or overrides fields, such as `crossOrigin`.
  defp client_data(authenticator, type, challenge, origin) do
    %{"type" => type, "challenge" => challenge, "origin" => origin}
    |> Map.merge(authenticator.client_data)
    |> Jason.encode!()
  end

  defp origin, do: Application.fetch_env!(:renga, :webauthn)[:origin]

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
