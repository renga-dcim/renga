defmodule Renga.Accounts.IdentityProviderTest do
  @moduledoc """
  A test sign-in of one provider revision (RFD 15, "Storage and changes").
  Its callback can only validate that exact revision and activate it; it
  never creates a session, links an identity, or counts as an account
  re-check.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "identity_provider_tests" do
    field :revision, :integer
    field :token_hash, :binary, redact: true
    field :state_hash, :binary, redact: true
    field :nonce, :string, redact: true
    field :verifier, :string, redact: true
    field :actor, :string
    field :expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string
    belongs_to :actor_user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
