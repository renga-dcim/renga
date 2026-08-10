defmodule RengaWeb.BodyDigestReaderTest do
  use ExUnit.Case, async: true

  alias RengaWeb.BodyDigestReader

  test "hashes every adapter chunk without retaining a raw body copy" do
    body = "first chunk|second chunk|third chunk"
    conn = Plug.Test.conn(:post, "/", body)
    {read, conn} = read_all(conn, [], length: 7, read_length: 7)

    assert IO.iodata_to_binary(Enum.reverse(read)) == body
    assert BodyDigestReader.digest(conn) == :crypto.hash(:sha256, body)
    assert BodyDigestReader.fetch_digest(conn) == {:ok, :crypto.hash(:sha256, body)}
    refute Map.has_key?(conn.assigns, :raw_body)
    assert conn.private[:renga_wire_body_sha256_context] == nil
  end

  test "empty bodies have the SHA-256 empty digest" do
    conn = Plug.Test.conn(:post, "/", "")
    assert {:ok, "", conn} = BodyDigestReader.read_body(conn, [])
    assert BodyDigestReader.digest(conn) == :crypto.hash(:sha256, "")
  end

  test "an unread body has no authenticated digest" do
    conn = Plug.Test.conn(:post, "/", "not read")
    assert BodyDigestReader.fetch_digest(conn) == :error
  end

  defp read_all(conn, chunks, opts) do
    case BodyDigestReader.read_body(conn, opts) do
      {:more, chunk, conn} -> read_all(conn, [chunk | chunks], opts)
      {:ok, chunk, conn} -> {[chunk | chunks], conn}
    end
  end
end
