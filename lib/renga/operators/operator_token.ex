defmodule Renga.Operators.OperatorToken do
  @moduledoc """
  A credential for the operator API (RFD 22).

  It belongs to the deployment, not to an organization or a user. The
  plaintext is shown once when the token is created; only its hash is kept.
  Its ID is immutable and is what audit records and idempotency keys refer
  to, while its name is for people.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Types.Cidr

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  # Each write scope includes the reads its automation needs to observe the
  # result; no scope implies an unrelated one.
  @scopes ~w(
    organizations:read organizations:write
    policy:read policy:write
    providers:read providers:write
    usage:read
    transfers:read transfers:write
  )

  schema "operator_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :scopes, {:array, :string}
    field :allowed_sources, {:array, Cidr}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  def scopes, do: @scopes

  def create_changeset(token, attrs, token_hash) when is_binary(token_hash) do
    token
    |> cast(attrs, [:name, :scopes, :allowed_sources, :expires_at])
    |> put_change(:token_hash, token_hash)
    |> update_change(:name, &String.trim/1)
    |> update_change(:scopes, &Enum.uniq/1)
    |> validate_required([:name, :scopes, :token_hash])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_name()
    |> validate_length(:scopes, min: 1)
    |> validate_subset(:scopes, @scopes)
    |> validate_future(:expires_at)
    |> validate_sources()
    |> unique_constraint(:name)
    |> unique_constraint(:token_hash)
  end

  def revoke_changeset(token, now), do: change(token, revoked_at: now)

  # Commands accept a token's ID or name, so a name shaped like an ID would
  # be unreachable by name, or name another token. Control characters would
  # break the command's tab-separated listing.
  defp validate_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      cond do
        Ecto.UUID.cast(name) != :error -> [name: "must not look like a token ID"]
        String.match?(name, ~r/[[:cntrl:]]/u) -> [name: "must not contain control characters"]
        true -> []
      end
    end)
  end

  # Peers are compared as IPv4 when they arrive as IPv4-mapped IPv6, so a
  # mapped prefix such as ::ffff:10.0.0.0/104 could never match. Ask for the
  # IPv4 prefix instead.
  defp validate_sources(changeset) do
    validate_change(changeset, :allowed_sources, fn :allowed_sources, sources ->
      if Enum.any?(sources, &match?(%Postgrex.INET{address: {0, 0, 0, 0, 0, 0xFFFF, _, _}}, &1)),
        do: [allowed_sources: "must use an IPv4 prefix rather than an IPv4-mapped IPv6 one"],
        else: []
    end)
  end

  defp validate_future(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if DateTime.after?(value, Renga.Time.utc_now_ms()),
        do: [],
        else: [{field, "must be in the future"}]
    end)
  end
end
