defmodule Renga.Topology.InterfaceNeighborEvidence do
  @moduledoc "Immutable LLDP/CDP evidence reported for one local interface."

  use Ecto.Schema
  import Ecto.Changeset

  alias Renga.Topology.NeighborIdentifier

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_neighbor_evidence" do
    field :protocol, :string
    field :remote_chassis_id, :string
    field :remote_chassis_id_kind, :string
    field :remote_chassis_id_normalized, :string
    field :remote_system_name, :string
    field :remote_port_id, :string
    field :remote_port_id_kind, :string
    field :remote_port_id_normalized, :string
    field :remote_port_description, :string
    field :ttl_seconds, :integer
    field :observed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :stale_reason, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :local_interface, Renga.Inventory.Interface
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :protocol,
      :remote_chassis_id,
      :remote_chassis_id_kind,
      :remote_system_name,
      :remote_port_id,
      :remote_port_id_kind,
      :remote_port_description,
      :ttl_seconds,
      :observed_at,
      :expires_at,
      :stale_at,
      :stale_reason,
      :metadata
    ])
    |> reject_fact_mutation()
    |> put_normalized_identifiers()
    |> validate_required([
      :organization_id,
      :local_interface_id,
      :source_id,
      :observation_id,
      :protocol,
      :remote_chassis_id,
      :remote_chassis_id_normalized,
      :remote_port_id,
      :remote_port_id_normalized,
      :ttl_seconds,
      :observed_at,
      :expires_at,
      :metadata
    ])
    |> validate_inclusion(:protocol, ~w(lldp cdp))
    |> validate_inclusion(:remote_chassis_id_kind, ~w(mac_address network_address local name))
    |> validate_inclusion(:remote_port_id_kind, ~w(mac_address local name))
    |> validate_length(:remote_chassis_id, max: 255, count: :codepoints)
    |> validate_length(:remote_chassis_id_normalized, max: 255, count: :codepoints)
    |> validate_length(:remote_system_name, max: 255, count: :codepoints)
    |> validate_length(:remote_port_id, max: 255, count: :codepoints)
    |> validate_length(:remote_port_id_normalized, max: 255, count: :codepoints)
    |> validate_length(:remote_port_description, max: 255, count: :codepoints)
    |> validate_number(:ttl_seconds, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_inclusion(:stale_reason, ~w(expired superseded withdrawn))
    |> check_constraint(:remote_chassis_id_kind,
      name: :interface_neighbor_evidence_valid_id_kinds
    )
    |> check_constraint(:remote_port_id_kind, name: :interface_neighbor_evidence_valid_id_kinds)
    |> check_constraint(:stale_reason, name: :interface_neighbor_evidence_stale_shape)
    |> assoc_constraint(:local_interface,
      name: :interface_neighbor_evidence_tenant_interface_fkey
    )
    |> assoc_constraint(:source, name: :interface_neighbor_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :interface_neighbor_evidence_tenant_observation_fkey)
    |> unique_constraint(
      [
        :organization_id,
        :observation_id,
        :local_interface_id,
        :protocol,
        :remote_chassis_id,
        :remote_port_id
      ],
      name: :interface_neighbor_evidence_observation_endpoint_index
    )
  end

  defp reject_fact_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) do
    if Map.keys(changes) -- [:stale_at, :stale_reason] == [],
      do: changeset,
      else: add_error(changeset, :base, "interface neighbor evidence facts are immutable")
  end

  defp reject_fact_mutation(changeset), do: changeset

  defp put_normalized_identifiers(changeset) do
    changeset
    |> put_normalized_identifier(
      :remote_chassis_id,
      :remote_chassis_id_kind,
      :remote_chassis_id_normalized
    )
    |> put_normalized_identifier(
      :remote_port_id,
      :remote_port_id_kind,
      :remote_port_id_normalized
    )
  end

  defp put_normalized_identifier(changeset, value_field, kind_field, normalized_field) do
    case {get_field(changeset, kind_field), get_field(changeset, value_field)} do
      {kind, value} when is_binary(value) ->
        put_change(
          changeset,
          normalized_field,
          if(normalized_field == :remote_chassis_id_normalized,
            do: NeighborIdentifier.normalize_chassis(kind, value),
            else: NeighborIdentifier.normalize_port(kind, value)
          )
        )

      _kind_and_value ->
        changeset
    end
  end
end
