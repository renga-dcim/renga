defmodule RengaWeb.BodyDigestReader do
  @moduledoc "Hashes bounded request bytes as Plug incrementally reads them."

  @digest_key :renga_wire_body_sha256
  @context_key :renga_wire_body_sha256_context

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:more, :ok] ->
        context = conn.private[@context_key] || :crypto.hash_init(:sha256)
        context = :crypto.hash_update(context, chunk)

        conn =
          if status == :ok do
            conn
            |> Plug.Conn.put_private(@digest_key, :crypto.hash_final(context))
            |> Plug.Conn.put_private(@context_key, nil)
          else
            Plug.Conn.put_private(conn, @context_key, context)
          end

        {status, chunk, conn}

      error ->
        error
    end
  end

  def fetch_digest(conn) do
    case conn.private[@digest_key] do
      digest when is_binary(digest) -> {:ok, digest}
      _ -> :error
    end
  end

  def digest(conn) do
    case fetch_digest(conn) do
      {:ok, digest} -> digest
      :error -> :crypto.hash(:sha256, "")
    end
  end
end
