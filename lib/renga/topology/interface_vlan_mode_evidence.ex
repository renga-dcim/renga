defmodule Renga.Topology.InterfaceVlanModeEvidence do
  @moduledoc "Observation-scoped interface mode report or authoritative withdrawal."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_vlan_mode_evidence" do
    field :mode, :string
    field :observed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:mode, :observed_at, :metadata])
    |> reject_mutation()
    |> validate_required([
      :organization_id,
      :interface_id,
      :source_id,
      :observation_id,
      :observed_at,
      :metadata
    ])
    |> validate_inclusion(:mode, ~w(access trunk tagged_all), allow_nil: true)
    |> assoc_constraint(:interface, name: :interface_vlan_mode_evidence_tenant_interface_fkey)
    |> assoc_constraint(:source, name: :interface_vlan_mode_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :interface_vlan_mode_evidence_tenant_observation_fkey)
    |> unique_constraint([:organization_id, :observation_id, :interface_id],
      name: :interface_vlan_mode_evidence_observation_link_index
    )
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "interface VLAN mode evidence is immutable")
  end

  defp reject_mutation(changeset), do: changeset
end
