defmodule Renga.Operators.Idempotency do
  @moduledoc """
  Makes non-idempotent operator writes safe to retry (RFD 22, "Writes").

  A request names an `Idempotency-Key`. Its namespace is the token's
  immutable ID, the HTTP method, and the canonical route, so two tokens or
  two operations never share a key. The completed response is stored with a
  digest of the normalized request for `retention_hours/0`:

    * a retry with the same request gets the stored response back, without
      the operation running again;
    * a different request under the same key is a conflict.

  `begin/1` and `finish!/2` run inside the operation's own transaction: the
  first serializes concurrent requests with the same key and notices one
  that already finished, and the second stores the response with the
  change, so a change never commits without its stored response.
  """

  import Ecto.Query

  alias Renga.Operators.OperatorToken
  alias Renga.Repo

  @retention_hours 24

  defmodule Key do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "operator_idempotency_keys" do
      field :method, :string
      field :route, :string
      field :key, :string
      field :request_digest, :binary, redact: true
      field :response_status, :integer
      field :response_body, :map
      field :expires_at, :utc_datetime_usec

      belongs_to :operator_token, OperatorToken

      timestamps(
        type: :utc_datetime_usec,
        autogenerate: {Renga.Time, :utc_now_ms, []},
        updated_at: false
      )
    end
  end

  @enforce_keys [:token_id, :method, :route, :key, :digest, :status, :render, :expires_at]
  defstruct @enforce_keys

  @typedoc """
  One request's idempotency: where its key lives, the digest of what it
  asked, and how to turn the operation's result into the stored response.
  """
  @type t :: %__MODULE__{
          token_id: Ecto.UUID.t(),
          method: String.t(),
          route: String.t(),
          key: String.t(),
          digest: binary(),
          status: pos_integer(),
          render: (term() -> map()),
          expires_at: DateTime.t()
        }

  @doc "How long a completed response is kept for retries."
  def retention_hours, do: @retention_hours

  @doc "The retention deadline for an operation beginning now."
  def expiration, do: DateTime.add(Renga.Time.utc_now_ms(), @retention_hours, :hour)

  @doc """
  Whether `key` can be an `Idempotency-Key`: 1 to 255 visible ASCII
  characters.
  """
  def valid_key?(key) when is_binary(key), do: key =~ ~r/\A[\x21-\x7e]{1,255}\z/
  def valid_key?(_key), do: false

  @doc """
  A digest of a request's parameters that ignores key order, so the same
  request always has the same digest.
  """
  def digest(params), do: :crypto.hash(:sha256, :erlang.term_to_binary(normalize(params)))

  defp normalize(map) when is_map(map),
    do: map |> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end) |> Enum.sort()

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  @doc """
  Looks up a completed response outside any transaction, so a sequential
  retry costs one read. Returns `{:ok, {status, body, expires_at}}`,
  `{:error, :conflict}` when the key was used for a different request, or
  `:none`.
  """
  def fetch(%__MODULE__{} = idempotency) do
    case Repo.one(live_query(idempotency)) do
      nil -> :none
      %Key{request_digest: digest} = key when digest == idempotency.digest -> {:ok, stored(key)}
      %Key{} -> {:error, :conflict}
    end
  end

  @doc """
  Starts an operation inside its transaction. Waits for any concurrent
  request with the same key, then returns `:ok` to go ahead or
  `{:error, :replayed}` when the same request completed meanwhile. Reusing
  the key for a different request returns `{:error,
  :idempotency_key_reused}`. A `nil` idempotency, as release commands pass,
  always goes ahead.
  """
  def begin(nil), do: :ok

  def begin(%__MODULE__{} = idempotency) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext('renga.operator_idempotency'), hashtext($1))",
      [
        lock_name(idempotency)
      ]
    )

    # An expired key no longer protects anything and is reused.
    Repo.delete_all(
      idempotency
      |> scope_query()
      |> where([key], key.expires_at <= ^Renga.Time.utc_now_ms())
    )

    case Repo.one(live_query(idempotency)) do
      nil -> :ok
      %Key{request_digest: digest} when digest == idempotency.digest -> {:error, :replayed}
      %Key{} -> {:error, :idempotency_key_reused}
    end
  end

  @doc """
  Stores the response for `result` with the change. Returns the response
  body and when it expires.
  """
  def finish!(nil, _result), do: :ok

  def finish!(%__MODULE__{} = idempotency, result) do
    body = idempotency.render.(result)

    Repo.insert!(%Key{
      operator_token_id: idempotency.token_id,
      method: idempotency.method,
      route: idempotency.route,
      key: idempotency.key,
      request_digest: idempotency.digest,
      response_status: idempotency.status,
      response_body: body,
      expires_at: idempotency.expires_at
    })

    :ok
  end

  defp scope_query(idempotency) do
    Key
    |> where([key], key.operator_token_id == ^idempotency.token_id)
    |> where([key], key.method == ^idempotency.method)
    |> where([key], key.route == ^idempotency.route)
    |> where([key], key.key == ^idempotency.key)
  end

  defp live_query(idempotency) do
    where(scope_query(idempotency), [key], key.expires_at > ^Renga.Time.utc_now_ms())
  end

  defp stored(%Key{} = key), do: {key.response_status, key.response_body, key.expires_at}

  defp lock_name(idempotency),
    do:
      Enum.join(
        [idempotency.token_id, idempotency.method, idempotency.route, idempotency.key],
        " "
      )
end
