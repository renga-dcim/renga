defmodule Renga.Inventory.ReconciliationLane do
  @moduledoc """
  Organization-local ordering, outstanding reservations and expiring ownership.

  Mutations belong to `ReconciliationWork`; neither a loaded lane nor its token
  grants authority outside a freshly fenced transaction.
  """
  use Ecto.Schema

  @primary_key {:organization_id, :binary_id, autogenerate: false}
  schema "reconciliation_lanes" do
    field :position, :integer, default: 0
    field :pending_units, :integer, default: 0
    field :pending_bytes, :integer, default: 0
    field :last_turn_at, :utc_datetime_usec
    field :token, Ecto.UUID
    field :work_id, Ecto.UUID
    field :version, :integer, default: 0
    field :expires_at, :utc_datetime_usec
  end
end
