defmodule Renga.Topology.InterfaceVlanEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @max_source_local_key_bytes 2_000

  schema "interface_vlan_evidence" do
    field :source_local_key, :string
    field :source_local_scope, :string
    field :vid, :integer
    field :tagging_mode, :string
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :vlan, Renga.Topology.Vlan
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :source_local_key,
      :source_local_scope,
      :vid,
      :tagging_mode,
      :metadata,
      :observed_at,
      :stale_at
    ])
    |> update_change(:source_local_key, &String.trim/1)
    |> validate_change(:source_local_key, fn :source_local_key, key ->
      if byte_size(key) <= @max_source_local_key_bytes,
        do: [],
        else: [source_local_key: "is too large"]
    end)
    |> reject_fact_mutation()
    |> validate_required([
      :organization_id,
      :interface_id,
      :source_id,
      :observation_id,
      :source_local_key,
      :vid,
      :tagging_mode,
      :metadata,
      :observed_at
    ])
    |> validate_length(:source_local_scope, max: 255, count: :codepoints)
    |> validate_number(:vid, greater_than_or_equal_to: 1, less_than_or_equal_to: 4094)
    |> validate_inclusion(:tagging_mode, ~w(tagged untagged))
    |> assoc_constraint(:interface, name: :interface_vlan_evidence_tenant_interface_fkey)
    |> assoc_constraint(:vlan, name: :interface_vlan_evidence_tenant_vlan_fkey)
    |> assoc_constraint(:source, name: :interface_vlan_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :interface_vlan_evidence_tenant_observation_fkey)
    |> unique_constraint([:organization_id, :observation_id, :interface_id, :source_local_key],
      name: :interface_vlan_evidence_observation_link_index
    )
  end

  defp reject_fact_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) do
    if Map.keys(changes) -- [:stale_at] == [],
      do: changeset,
      else: add_error(changeset, :base, "interface VLAN evidence facts are immutable")
  end

  defp reject_fact_mutation(changeset), do: changeset
end
