defmodule Renga.Accounts.IdentityProviderEvent do
  @moduledoc """
  A change to a deployment identity provider, with who made it and which
  fields changed but never a secret (RFD 15, "Storage and changes").
  Deployment providers belong to no organization, so these are kept here
  rather than in an organization's Activity feed.
  """

  use Ecto.Schema

  @kinds ~w(created updated revision_pending revision_discarded activated enabled disabled removed secret_reencrypted mfa_marked mfa_unmarked)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "identity_provider_events" do
    field :kind, :string
    field :revision, :integer
    field :changed, {:array, :string}, default: []
    field :actor, :string

    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string
    belongs_to :actor_user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end

  def kinds, do: @kinds
end
