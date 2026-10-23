defmodule Renga.Operators.InvitationDelivery do
  @moduledoc false

  use Ecto.Schema

  alias Renga.Accounts.OrganizationInvitation

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "operator_invitation_deliveries" do
    field :url_ciphertext, :binary, redact: true
    field :url_key_id, :string
    field :attempts, :integer, default: 0
    field :available_at, :utc_datetime_usec
    field :lease_id, :binary_id
    field :lease_expires_at, :utc_datetime_usec

    belongs_to :invitation, OrganizationInvitation

    timestamps()
  end
end
