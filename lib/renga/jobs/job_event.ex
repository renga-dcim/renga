defmodule Renga.Jobs.JobEvent do
  @moduledoc """
  One immutable entry in a job's history (RFD 9).

  A database trigger rejects updates and deletes; events disappear only with
  their job, when retention removes it, or with their organization.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Jobs.Job

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(created leased started progress output succeeded failed cancel_requested
            cancelled lease_lost expired uncertain resolved)
  @actor_types ~w(user agent system)

  schema "job_events" do
    field :sequence, :integer
    # The agent's own number for the report within an attempt; see report/7.
    field :report_sequence, :integer
    field :attempt, :integer
    field :type, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :payload, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :job, Job

    timestamps(
      type: :utc_datetime_usec,
      updated_at: false,
      autogenerate: {Renga.Time, :utc_now_ms, []}
    )
  end

  def types, do: @types
  def actor_types, do: @actor_types
end
