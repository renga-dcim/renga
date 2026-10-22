defmodule Renga.Telemetry.Batch do
  @moduledoc """
  A telemetry batch an installation delivered (RFD 10, "Measured history").

  Only the batch's identity is kept: its source, the replay ID the agent gave
  it, and a digest of its payload. Redelivery of the same batch is
  recognised by those, so a retried batch is accepted once.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "telemetry_batches" do
    field :replay_id, :string
    field :version, :integer
    field :payload_digest, :string
    field :sample_count, :integer
    field :received_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
  end
end
