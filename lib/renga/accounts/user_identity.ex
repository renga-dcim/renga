defmodule Renga.Accounts.UserIdentity do
  @moduledoc """
  A user's identity at a provider (RFD 15, "Identities and accounts"): the
  provider's stable subject for them. An OpenID Connect identity uses the ID
  token's `sub`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_identities" do
    field :subject, :string
    field :email, :string
    # Whether the provider verified `email` when it last asserted it.
    field :email_verified, :boolean, default: false
    field :last_signed_in_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User
    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string

    timestamps(type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []})
  end
end
