defmodule Renga.SecuritySettings.Setting do
  @moduledoc """
  One organization's value for one security setting (RFD 19), and who last
  changed it. `value` wraps the setting's value as `%{"value" => value}`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "organization_security_settings" do
    field :name, :string
    field :value, :map
    field :changed_by, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :changed_by_user, Renga.Accounts.User

    timestamps()
  end
end
