defmodule Renga.Inventory.ComponentEvidence do
  @moduledoc """
  Typed observation-scoped evidence for a physical component.

  Source identity and common asset fields stay queryable while kind-specific
  attributes remain shape-open and the immutable observation preserves raw input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(cpu memory disk module)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "component_evidence" do
    field :kind, :string
    field :source_local_id, :string
    field :name, :string
    field :model, :string
    field :slot, :string
    field :path, :string
    field :serial_number, :string
    field :part_number, :string
    field :attributes, :map, default: %{}
    field :raw_metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :kind,
      :source_local_id,
      :name,
      :model,
      :slot,
      :path,
      :serial_number,
      :part_number,
      :attributes,
      :raw_metadata,
      :observed_at
    ])
    |> trim_required(:source_local_id)
    |> trim_optional(:name)
    |> trim_optional(:model)
    |> trim_optional(:slot)
    |> trim_optional(:path)
    |> trim_optional(:serial_number)
    |> trim_optional(:part_number)
    |> validate_required([
      :organization_id,
      :resource_id,
      :source_id,
      :observation_id,
      :kind,
      :source_local_id,
      :observed_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_module_position()
    |> validate_map(:attributes)
    |> validate_map(:raw_metadata)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :component_evidence_tenant_resource_fkey)
    |> assoc_constraint(:source, name: :component_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :component_evidence_tenant_observation_fkey)
    |> check_constraint(:kind, name: :component_evidence_valid_kind)
    |> check_constraint(:slot,
      name: :component_evidence_module_position,
      message: "slot or path is required for module evidence"
    )
    |> unique_constraint([:organization_id, :observation_id, :kind, :source_local_id],
      name: :component_evidence_observation_identity_index
    )
  end

  defp trim_required(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp trim_optional(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> empty_to_nil()
      value -> value
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp validate_module_position(changeset) do
    if get_field(changeset, :kind) == "module" and is_nil(get_field(changeset, :slot)) and
         is_nil(get_field(changeset, :path)) do
      add_error(changeset, :slot, "slot or path is required for module evidence")
    else
      changeset
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
