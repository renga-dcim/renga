defmodule Renga.Inventory.CollectorTargetResource do
  @moduledoc """
  A resource a collector target reported (RFD 11, "Observation payload").

  Present while `withdrawn_at` is unset or older than `last_reported_at`. Only
  a complete report that reached the target withdraws a resource it no longer
  contains; partial, failed, and unreachable reports leave it alone, and an
  older report replayed late cannot bring it back.

  For a hypervisor, `domain` is the latest libvirt view of the VM and
  `active_since` when its latest run of active reports began; an inactive
  definition has none. Only an active domain claims to be running there.

  A run ends only when the hypervisor reports the domain inactive or a
  complete report withdraws it. A gap in reports, such as an unreachable
  target or a stopped agent, does not: libvirt cannot say whether the domain
  restarted meanwhile, so `active_since` may predate a restart in the gap.
  Placement freshness already discounts a run whose reports have stopped.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "collector_target_resources" do
    field :first_reported_at, :utc_datetime_usec
    field :last_reported_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec
    field :domain, :map
    field :domain_reported_at, :utc_datetime_usec
    field :active_since, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :source, Source
    belongs_to :target, CollectorTarget
    belongs_to :resource, Resource

    timestamps()
  end

  # Running, idle, paused, and shutting-down domains occupy their hypervisor.
  @active_domain_states ~w(running idle paused shutting_down)

  @doc "Whether a reported domain state occupies the hypervisor."
  def active_domain_state?(state), do: state in @active_domain_states

  @doc """
  Whether the domain view was reported after the member's latest withdrawal.
  A withdrawal ends the domain's active run, so evidence from before it can
  neither place the VM nor carry its run into a later report.
  """
  def domain_current?(%__MODULE__{domain_reported_at: nil}), do: false
  def domain_current?(%__MODULE__{withdrawn_at: nil}), do: true

  def domain_current?(%__MODULE__{domain_reported_at: reported_at, withdrawn_at: withdrawn_at}),
    do: DateTime.compare(reported_at, withdrawn_at) == :gt

  @doc "Whether the target still reports the resource."
  def present?(%__MODULE__{withdrawn_at: nil}), do: true

  def present?(%__MODULE__{withdrawn_at: withdrawn_at, last_reported_at: last_reported_at}),
    do: DateTime.compare(last_reported_at, withdrawn_at) == :gt
end
