defmodule Renga.Topology.TopologySnapshotEvent do
  @moduledoc "Immutable source/resource boundary for an explicitly complete topology section."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "topology_snapshot_events" do
    field :section, :string
    field :observed_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:section, :observed_at])
    |> reject_mutation()
    |> validate_required([
      :organization_id,
      :resource_id,
      :source_id,
      :observation_id,
      :section,
      :observed_at
    ])
    |> validate_inclusion(
      :section,
      ~w(interface_vlans interface_neighbors interface_relationships)
    )
    |> check_constraint(:section, name: :topology_snapshot_events_valid_section)
    |> assoc_constraint(:resource, name: :topology_snapshot_events_tenant_resource_fkey)
    |> assoc_constraint(:source, name: :topology_snapshot_events_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :topology_snapshot_events_tenant_observation_fkey)
    |> unique_constraint([:organization_id, :observation_id, :resource_id, :section],
      name: :topology_snapshot_events_observation_section_index
    )
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "topology snapshot event is immutable")
  end

  defp reject_mutation(changeset), do: changeset
end
