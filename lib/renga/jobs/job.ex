defmodule Renga.Jobs.Job do
  @moduledoc """
  One capability run requested of one agent (RFD 9).

  The row is a projection of the job's `Renga.Jobs.JobEvent` history. Only
  `Renga.Jobs` changes it, and always together with the event that explains
  the change, so nothing here is castable from outside.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Agent
  alias Renga.Inventory.Resource
  alias Renga.Jobs.JobEvent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @states ~w(queued leased running succeeded failed cancelled expired uncertain)
  @finished_states ~w(succeeded failed cancelled expired)
  @leased_states ~w(leased running)
  @open_states ~w(queued leased running)

  schema "jobs" do
    field :batch_id, :binary_id
    field :capability, :string
    field :capability_version, :integer
    field :risk_class, :string
    field :retry_class, :string
    field :parameters, :map, default: %{}
    field :requested_by_type, :string
    field :idempotency_key, :string
    field :state, :string
    field :attempts, :integer, default: 0
    field :max_attempts, :integer
    field :not_after, :utc_datetime_usec
    field :lease_token_hash, :binary, redact: true
    field :report_token_hash, :binary, redact: true
    field :leased_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :result, :map
    field :failure_reason, :string
    field :output_bytes, :integer, default: 0
    field :output_limit_bytes, :integer
    field :timeout_ms, :integer
    field :last_sequence, :integer, default: 0
    # Privileged jobs only (RFD 13): the binding requested under, and the
    # current signed-lease offer.
    field :target_binding_version, :integer
    field :offer_token_hash, :binary, redact: true
    field :offer_nonce, :string
    field :offer_expires_at, :utc_datetime_usec
    # Set on reads when the reader may not see this job's parameters,
    # result, and agent reports, which are then withheld (RFD 12).
    field :payload_hidden, :boolean, virtual: true, default: false

    # Set on jobs imported from another deployment (RFD 20): history that
    # never leases, retries, or runs, and that no one can change.
    field :imported_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :agent, Agent
    # The resource the job was requested from, for context; the agent is the
    # target.
    belongs_to :resource, Resource
    belongs_to :requested_by_user, User
    belongs_to :target_binding, Renga.Jobs.TargetBinding
    has_many :events, JobEvent, preload_order: [asc: :sequence]

    timestamps()
  end

  def states, do: @states
  def finished_states, do: @finished_states
  def leased_states, do: @leased_states
  def open_states, do: @open_states

  @doc "The `name@version` key that identifies the job's capability."
  def capability_key(%__MODULE__{capability: name, capability_version: version}),
    do: "#{name}@#{version}"

  @doc "Whether leasing the job needs a request signed with an approved key (RFD 13)."
  def privileged?(%__MODULE__{risk_class: risk_class}), do: risk_class != "observe"

  def finished?(%__MODULE__{state: state}), do: state in @finished_states
  def open?(%__MODULE__{state: state}), do: state in @open_states
end
