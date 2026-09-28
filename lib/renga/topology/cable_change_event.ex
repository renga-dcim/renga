defmodule Renga.Topology.CableChangeEvent do
  @moduledoc "Append-only history for reconciled cable transitions."

  use Ecto.Schema

  import Ecto.Changeset

  @actions ~w(created updated removed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "cable_change_events" do
    field :sequence, :integer, read_after_writes: true
    field :cable_id, :binary_id
    field :assertion_id, :binary_id
    field :action, :string
    field :changes, :map, default: %{}
    field :snapshot, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    field :actor_user_id, :binary_id
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_a, Renga.Inventory.Interface
    belongs_to :interface_b, Renga.Inventory.Interface
    belongs_to :source, Renga.Inventory.Source
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :changes, :snapshot, :occurred_at, :metadata])
    |> validate_required([
      :organization_id,
      :cable_id,
      :action,
      :changes,
      :snapshot,
      :occurred_at,
      :metadata
    ])
    |> validate_inclusion(:action, @actions)
    |> assoc_constraint(:interface_a, name: :cable_change_events_tenant_a_fkey)
    |> assoc_constraint(:interface_b, name: :cable_change_events_tenant_b_fkey)
    |> assoc_constraint(:source, name: :cable_change_events_tenant_source_fkey)
  end
end
