defmodule Renga.VaultTest do
  # Changes the application environment, so not async.
  use ExUnit.Case, async: false

  alias Renga.Vault

  defp key, do: Base.encode64(:crypto.strong_rand_bytes(32))

  defp with_keys(spec, fun) do
    previous = Application.get_env(:renga, Vault)
    Application.put_env(:renga, Vault, keys: spec)

    try do
      fun.()
    after
      Application.put_env(:renga, Vault, previous)
    end
  end

  test "round-trips a secret bound to its associated data" do
    {:ok, key_id, ciphertext} = Vault.encrypt("s3cret", "provider:okta")

    assert key_id == Vault.current_key_id()
    refute ciphertext =~ "s3cret"
    assert {:ok, "s3cret"} = Vault.decrypt(key_id, ciphertext, "provider:okta")
    assert {:error, :invalid} = Vault.decrypt(key_id, ciphertext, "provider:other")
  end

  test "each encryption uses a fresh nonce" do
    {:ok, _, first} = Vault.encrypt("same", "aad")
    {:ok, _, second} = Vault.encrypt("same", "aad")
    assert first != second
  end

  test "rejects a tampered ciphertext" do
    {:ok, key_id, <<head::binary-size(30), byte, rest::binary>>} = Vault.encrypt("secret", "aad")
    tampered = head <> <<Bitwise.bxor(byte, 1)>> <> rest

    assert {:error, :invalid} = Vault.decrypt(key_id, tampered, "aad")
    assert {:error, :invalid} = Vault.decrypt(key_id, "short", "aad")
  end

  test "the first key encrypts and every listed key decrypts" do
    old = key()
    {old_id, old_ciphertext} = with_keys("old:#{old}", fn -> elem3(Vault.encrypt("a", "aad")) end)

    with_keys("new:#{key()},old:#{old}", fn ->
      assert Vault.current_key_id() == "new"
      assert {:ok, "new", _} = Vault.encrypt("b", "aad")
      assert {:ok, "a"} = Vault.decrypt(old_id, old_ciphertext, "aad")
    end)

    with_keys("new:#{key()}", fn ->
      assert {:error, :unknown_key} = Vault.decrypt(old_id, old_ciphertext, "aad")
    end)
  end

  test "without a key nothing is encrypted" do
    with_keys(nil, fn ->
      assert Vault.current_key_id() == nil
      assert {:error, :no_key} = Vault.encrypt("secret", "aad")
    end)
  end

  test "a malformed key list raises" do
    for spec <- ["nokey", "a:not-base64!", "a:#{Base.encode64("short")}", "a:#{key()},a:#{key()}"] do
      assert_raise ArgumentError, fn -> Vault.parse_keys(spec) end
    end
  end

  defp elem3({:ok, id, ciphertext}), do: {id, ciphertext}
end
