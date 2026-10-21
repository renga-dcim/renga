defmodule Renga.Accounts.OrganizationInvitation do
  @moduledoc """
  An offer of one base role in one organization to one email address.

  The token is a single-use secret: only its SHA-256 hash is stored, it
  expires after `validity_days/0`, it can be revoked, and accepting it
  records who accepted. Acceptance requires a signed-in account that has
  confirmed the invited address, so the link alone grants nothing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @roles ~w(owner admin member viewer)
  @validity_days 7
  @token_bytes 32

  schema "organization_invitations" do
    field :email, :string
    field :role, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :invited_by_user, User
    belongs_to :accepted_by_user, User
    belongs_to :revoked_by_user, User

    timestamps()
  end

  def validity_days, do: @validity_days

  @doc "A new URL-safe token and the hash to store for it."
  def build_token do
    token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    {token, hash_token(token)}
  end

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  def create_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email, :role])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:email,
      name: :organization_invitations_open_email_index,
      message: "already has an open invitation"
    )
  end

  @doc "Whether the invitation can still be accepted at `now`."
  def open?(%__MODULE__{accepted_at: nil, revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def open?(%__MODULE__{}, _now), do: false
end
