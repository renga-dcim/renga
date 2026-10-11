defmodule Renga.Inventory.Agent do
  @moduledoc """
  Registered runtime agent that reports through an organization intake credential.

  A source identifies provenance; an agent identifies one running reporter with
  its own installation UUID, version, capabilities, and liveness lease.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active disabled)
  @max_string_length 255
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "agents" do
    field :name, :string
    field :status, :string, default: "active"
    field :installation_id, :binary_id
    field :version, :string
    field :capabilities, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :registered_at, :utc_datetime_usec
    # The latest authenticated API request, whatever became of its payload.
    # Set by intake authentication, never cast.
    field :last_contacted_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :source, Source
    has_one :lease, AgentLease

    timestamps()
  end

  @doc """
  The last reported observation queue health, or `nil` when no complete,
  valid report is stored. Check-ins omitting this metadata retain the old report.

  `dropped` totals the entries the agent removed undelivered (for space, by age,
  rejected, or unreadable) since it last started; the backlog itself survives
  restarts. Legacy metadata may predate intake validation, so it is checked
  again before presentation rather than coerced into a healthy empty queue.
  """
  def observation_queue(%__MODULE__{metadata: %{"observation_queue" => queue}}) do
    if AgentPayload.observation_queue_errors(queue) == [] do
      dropped_for_space = Map.fetch!(queue, "dropped_for_space")
      expired = Map.fetch!(queue, "expired")
      rejected = Map.fetch!(queue, "rejected")
      unreadable = Map.fetch!(queue, "unreadable")

      %{
        entries: Map.fetch!(queue, "entries"),
        bytes: Map.fetch!(queue, "bytes"),
        oldest_age_seconds: Map.fetch!(queue, "oldest_age_seconds"),
        dropped_for_space: dropped_for_space,
        expired: expired,
        rejected: rejected,
        unreadable: unreadable,
        dropped: dropped_for_space + expired + rejected + unreadable
      }
    end
  end

  def observation_queue(_agent), do: nil

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :status, :version, :capabilities, :metadata, :registered_at],
      empty_values: []
    )
    |> update_change(:name, &String.trim/1)
    |> validate_change(:name, fn :name, name ->
      if name == "", do: [name: "can't be blank"], else: []
    end)
    |> validate_required([:organization_id, :source_id, :name, :status, :registered_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:version, max: @max_string_length)
    |> validate_capabilities()
    |> check_constraint(:metadata,
      name: :agents_metadata_size,
      message: "must encode to at most 16000 bytes"
    )
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source, name: :agents_organization_source_fkey)
    |> unique_constraint([:organization_id, :source_id])
    |> unique_constraint(:installation_id,
      name: :agents_organization_installation_id_index
    )
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, capabilities ->
      cond do
        not Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) ->
          [capabilities: "must contain only non-empty strings"]

        Enum.any?(capabilities, &(String.length(&1) > @max_string_length)) ->
          [capabilities: "must be at most #{@max_string_length} characters"]

        true ->
          []
      end
    end)
  end
end
