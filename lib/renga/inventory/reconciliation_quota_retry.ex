defmodule Renga.Inventory.ReconciliationQuotaRetry do
  @moduledoc """
  One resource-capacity retry per immutable observation. The existing work owns
  its pending reservation, retry time and fenced generation; this row survives
  retries and restarts until a non-quota terminal outcome. Mutations belong to
  `ReconciliationWork` and share the disposition transaction.
  """
  use Ecto.Schema

  @primary_key {:work_id, :binary_id, autogenerate: false}
  schema "reconciliation_quota_retries" do
    field :observation_id, Ecto.UUID
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
