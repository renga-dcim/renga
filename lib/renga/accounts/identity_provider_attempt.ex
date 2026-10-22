defmodule Renga.Accounts.IdentityProviderAttempt do
  @moduledoc """
  The server's half of a provider sign-in attempt (RFD 15, "Sign-in flow"):
  the hash of its `state`, the provider revision it started with, and when it
  expires. A callback deletes it before exchanging the code, so an attempt
  completes at most once even when its session cookie is copied.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "identity_provider_attempts" do
    field :revision, :integer
    field :state_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec

    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
