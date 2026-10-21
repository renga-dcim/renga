defmodule Renga.Vault do
  @moduledoc """
  Encrypts secrets Renga must read back, such as identity provider client
  secrets (RFD 15, "Storage and changes"), with AES-256-GCM.

  Keys come from the environment at boot (`ENCRYPTION_KEYS`) as a
  comma-separated list of `id:base64-key` pairs. The first key encrypts; every
  listed key decrypts. Each ciphertext is stored beside the ID of the key that
  sealed it, so an operator rotates by putting a new key first, re-encrypting,
  and then removing the old one.

  Callers pass associated data naming what the secret belongs to, so a
  ciphertext copied to another row does not decrypt there.
  """

  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc "The ID of the key new secrets are encrypted with, or nil when none is configured."
  def current_key_id do
    case keys() do
      [{id, _key} | _] -> id
      [] -> nil
    end
  end

  @doc "Encrypts `plaintext` bound to `aad`. Returns `{:ok, key_id, ciphertext}`."
  def encrypt(plaintext, aad) when is_binary(plaintext) and is_binary(aad) do
    case keys() do
      [{id, key} | _] ->
        iv = :crypto.strong_rand_bytes(@iv_bytes)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @tag_bytes, true)

        {:ok, id, iv <> tag <> ciphertext}

      [] ->
        {:error, :no_key}
    end
  end

  @doc "Decrypts a ciphertext sealed by `encrypt/2` with the key `key_id` and the same `aad`."
  def decrypt(
        key_id,
        <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>,
        aad
      )
      when is_binary(aad) do
    with {:ok, key} <- fetch_key(key_id) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :invalid}
      end
    end
  end

  def decrypt(_key_id, _ciphertext, _aad), do: {:error, :invalid}

  defp fetch_key(key_id) do
    case List.keyfind(keys(), key_id, 0) do
      {_id, key} -> {:ok, key}
      nil -> {:error, :unknown_key}
    end
  end

  @doc """
  The configured keys, current first. Raises on a malformed list, so a typo
  in the environment fails at boot instead of on the first secret.
  """
  def keys do
    :renga
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keys, [])
    |> parse_keys()
  end

  @doc false
  def parse_keys(keys) when is_list(keys), do: keys

  def parse_keys(nil), do: []

  def parse_keys(spec) when is_binary(spec) do
    keys =
      spec
      |> String.split(",", trim: true)
      |> Enum.map(&parse_key/1)

    ids = Enum.map(keys, &elem(&1, 0))

    if length(Enum.uniq(ids)) != length(ids),
      do: raise(ArgumentError, "ENCRYPTION_KEYS lists a key ID twice")

    keys
  end

  defp parse_key(entry) do
    with [id, encoded] <- String.split(String.trim(entry), ":", parts: 2),
         true <- Regex.match?(~r/^[A-Za-z0-9_.-]{1,32}$/, id),
         {:ok, key} when byte_size(key) == @key_bytes <- Base.decode64(encoded) do
      {id, key}
    else
      _ ->
        raise ArgumentError,
              "each ENCRYPTION_KEYS entry must be id:base64, with a 32-byte key " <>
                "(generate one with: openssl rand -base64 32)"
    end
  end
end
