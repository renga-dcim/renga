defmodule Renga.Jobs.EvidenceReservation do
  @moduledoc "Historical attempt authority and unused protected evidence allowance."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "job_evidence_reservations" do
    field :organization_id, Ecto.UUID
    field :job_id, Ecto.UUID
    field :agent_id, Ecto.UUID
    field :installation_id, Ecto.UUID
    field :attempt, :integer
    field :token_hash, :binary, redact: true
    field :remaining_items, :integer
    field :remaining_bytes, :integer
  end
end
