defmodule Renga.Operators do
  @moduledoc """
  Operator tokens: the credentials of the operator API (RFD 22).

  An operator token belongs to the deployment and authenticates automation
  that runs it, such as a control plane. It never reads or changes an
  organization's inventory and never stands in for a person. Tokens are
  created and revoked with release commands; through the API a token can only
  revoke itself.

  Authentication here is separate from user sessions and intake keys: a token
  is checked against its hash, revocation, expiry, and source addresses on
  every request.
  """

  import Ecto.Query

  alias Renga.DeploymentAudit
  alias Renga.Operators.OperatorToken
  alias Renga.Repo
  alias Renga.Types.Inet

  @token_prefix "renga_operator_"
  @token_bytes 32

  defdelegate scopes, to: OperatorToken

  @doc """
  Creates a token and returns it with its one-time plaintext value, which
  exists only once the token and its audit event are committed.

  `attrs` takes `:name`, `:scopes`, and optionally `:expires_at` and
  `:allowed_sources`, a list of CIDR prefixes the token may be used from.
  `context` names who is creating it (`Renga.DeploymentAudit`).
  """
  def create_token(attrs, context) do
    plaintext = generate_token()

    DeploymentAudit.mutate(context, "operator_token.create", fn ->
      case %OperatorToken{}
           |> OperatorToken.create_changeset(attrs, hash_token(plaintext))
           |> Repo.insert() do
        {:ok, token} ->
          {:ok, {token, plaintext},
           %{target_id: token.id, changed: ~w(name scopes allowed_sources expires_at)}}

        {:error, changeset} ->
          {:error, changeset, %{}}
      end
    end)
  end

  @doc """
  Lists every token, revoked ones included. The schema redacts each token's
  hash; nothing here holds a plaintext token.
  """
  def list_tokens do
    OperatorToken
    |> order_by([token], asc: token.inserted_at, asc: token.id)
    |> Repo.all()
  end

  @doc """
  Finds a token by its ID or its name.
  """
  def get_token(id_or_name) when is_binary(id_or_name) do
    query =
      if OperatorToken.id_shaped?(id_or_name),
        do: where(OperatorToken, [token], token.id == ^id_or_name),
        else: where(OperatorToken, [token], token.name == ^id_or_name)

    Repo.one(query)
  end

  @doc """
  Revokes a token on behalf of `context`. Revoking an already revoked token
  succeeds and keeps the original revocation time.
  """
  def revoke_token(%OperatorToken{id: id}, context) do
    DeploymentAudit.mutate(context, "operator_token.revoke", fn ->
      token =
        OperatorToken
        |> where([token], token.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if token.revoked_at do
        {:ok, token, %{target_id: id}}
      else
        token = token |> OperatorToken.revoke_changeset(Renga.Time.utc_now_ms()) |> Repo.update!()
        {:ok, token, %{target_id: id, changed: ~w(revoked_at)}}
      end
    end)
  end

  @doc """
  Returns whether any token could authenticate now. Without one the operator
  API is off and no request reaches it.
  """
  def enabled? do
    now = Renga.Time.utc_now_ms()

    OperatorToken
    |> where([token], is_nil(token.revoked_at))
    |> where([token], is_nil(token.expires_at) or token.expires_at > ^now)
    |> Repo.exists?()
  end

  @doc """
  Authenticates a bearer token presented from `peer`, the address of the
  connection the request arrived on.

  Every failure returns the same `:error` from the same single query, so the
  response does not say whether a token was unknown, revoked, expired, or
  used from the wrong address.
  """
  def authenticate(@token_prefix <> _rest = plaintext, peer) when is_tuple(peer) do
    now = Renga.Time.utc_now_ms()
    token_hash = hash_token(plaintext)
    peer = %Postgrex.INET{address: unmap_ipv4(peer), netmask: nil}

    OperatorToken
    |> where([token], token.token_hash == ^token_hash)
    |> where([token], is_nil(token.revoked_at))
    |> where([token], is_nil(token.expires_at) or token.expires_at > ^now)
    |> where(
      [token],
      fragment("cardinality(?) = 0", token.allowed_sources) or
        fragment("? <<= ANY(?)", type(^peer, Inet), token.allowed_sources)
    )
    |> Repo.one()
    |> case do
      %OperatorToken{} = token -> {:ok, token}
      nil -> :error
    end
  end

  def authenticate(_plaintext, _peer), do: :error

  @doc """
  Returns whether `token` holds `scope`. A write scope includes the matching
  read (RFD 22), and no scope implies an unrelated one.
  """
  def authorized?(%OperatorToken{scopes: scopes}, scope) do
    scope in scopes or
      case String.split(scope, ":") do
        [area, "read"] -> "#{area}:write" in scopes
        _other -> false
      end
  end

  # A dual-stack listener reports IPv4 peers as IPv4-mapped IPv6 addresses;
  # compare them as IPv4 so `10.0.0.0/8` matches them.
  defp unmap_ipv4({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8), Bitwise.band(low, 0xFF)}
  end

  defp unmap_ipv4(address), do: address

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
  end

  # Tokens have full random entropy, so a fast hash is enough, as for intake
  # keys (RFD 3).
  defp hash_token(plaintext), do: :crypto.hash(:sha256, plaintext)
end
