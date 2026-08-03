defmodule Renga.Inventory.Agent do
  @moduledoc """
  Registered runtime agent that reports through a source credential.

  A source identifies provenance and authenticates requests; an agent identifies
  one running reporter with its own version, capabilities, and liveness lease.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active disabled)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "agents" do
    field :name, :string
    field :status, :string, default: "active"
    field :version, :string
    field :capabilities, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :registered_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :source, Source
    has_one :lease, AgentLease

    timestamps()
  end

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
    |> validate_capabilities()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source)
    |> unique_constraint([:organization_id, :source_id, :name])
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, capabilities ->
      if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) do
        []
      else
        [capabilities: "must contain only non-empty strings"]
      end
    end)
  end
end
