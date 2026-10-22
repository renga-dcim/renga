defmodule Renga.Limits.OrganizationLimit do
  @moduledoc """
  An operator's override of one limit for one organization (RFD 21).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "organization_limits" do
    field :name, :string
    field :value, :integer

    belongs_to :organization, Renga.Accounts.Organization

    timestamps()
  end
end
