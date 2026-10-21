defmodule Renga.Release.CLI do
  @moduledoc """
  The `renga-admin` release command: operator tasks run on the server.

  It reaches the same domain functions as the operator API (RFD 22), so a
  deployment without network access to that API can be run the same way.
  `bin/renga-admin` calls `main/1` from a built release, and
  `mix renga.admin` does in development.
  """

  alias Renga.Operators

  @usage """
  Usage:
    renga-admin operator-tokens create --name NAME --scope SCOPE [--scope SCOPE...]
                                       [--expires-at ISO8601] [--source CIDR...]
    renga-admin operator-tokens list
    renga-admin operator-tokens revoke ID_OR_NAME
  """

  @doc """
  Runs a command and returns its exit status. Output goes to stdout, errors to
  stderr.
  """
  def run(argv)

  def run(["operator-tokens", "create" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [name: :string, scope: :keep, expires_at: :string, source: :keep]
      )

    with :ok <- no_extra_args(rest, invalid),
         {:ok, expires_at} <- parse_expiry(opts[:expires_at]) do
      attrs = %{
        name: opts[:name],
        scopes: Keyword.get_values(opts, :scope),
        allowed_sources: Keyword.get_values(opts, :source),
        expires_at: expires_at
      }

      case Operators.create_token(attrs) do
        {:ok, {token, plaintext}} ->
          IO.puts("Created operator token #{token.name} (#{token.id}).")
          IO.puts("Store it now; it is not shown again:\n")
          IO.puts(plaintext)
          0

        {:error, changeset} ->
          error(changeset_errors(changeset))
      end
    end
  end

  def run(["operator-tokens", "list"]) do
    now = Renga.Time.utc_now_ms()

    for token <- Operators.list_tokens() do
      IO.puts(
        Enum.join(
          [
            token.id,
            token.name,
            token_status(token, now),
            Enum.join(token.scopes, ","),
            sources(token.allowed_sources),
            if(token.expires_at,
              do: "expires " <> DateTime.to_iso8601(token.expires_at),
              else: ""
            )
          ],
          "\t"
        )
      )
    end

    0
  end

  def run(["operator-tokens", "revoke", id_or_name]) do
    case Operators.get_token(id_or_name) do
      nil ->
        error("no operator token named or with ID #{id_or_name}")

      token ->
        {:ok, token} = Operators.revoke_token(token)
        IO.puts("Revoked operator token #{token.name} (#{token.id}).")
        0
    end
  end

  def run(_argv), do: error(@usage)

  @doc """
  Entry point for `bin/renga-admin`: starts only the database, runs the
  command, and halts with its status.
  """
  def main(argv) do
    Renga.Release.with_repos(fn -> run(argv) end) |> System.halt()
  end

  defp no_extra_args([], []), do: :ok
  defp no_extra_args(_rest, _invalid), do: error(@usage)

  defp parse_expiry(nil), do: {:ok, nil}

  defp parse_expiry(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, Renga.Time.floor_to_millisecond(datetime)}

      {:error, _reason} ->
        error("--expires-at must be an ISO 8601 time, such as 2027-01-01T00:00:00Z")
    end
  end

  defp token_status(token, now) do
    cond do
      token.revoked_at -> "revoked"
      token.expires_at && not DateTime.after?(token.expires_at, now) -> "expired"
      true -> "active"
    end
  end

  defp sources([]), do: "any source"
  defp sources(cidrs), do: Enum.map_join(cidrs, ",", &format_cidr/1)

  defp format_cidr(%Postgrex.INET{address: address, netmask: netmask}),
    do: "#{:inet.ntoa(address)}/#{netmask}"

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("\n", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error(message) do
    IO.puts(:stderr, message)
    1
  end
end
