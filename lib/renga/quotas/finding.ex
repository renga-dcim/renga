defmodule Renga.Quotas.Finding do
  @moduledoc "An organization-level quota condition; workflow lives in the shared Inbox."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "organization_quota_findings" do
    belongs_to :organization, Renga.Accounts.Organization
    field :name, :string
    field :used, :integer
    field :capacity, :integer
    field :opened_at, :utc_datetime_usec
    field :last_observed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
  end
end
