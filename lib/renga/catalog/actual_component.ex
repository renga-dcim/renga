defmodule Renga.Catalog.ActualComponent do
  @moduledoc """
  Source-neutral canonical projection of an observed physical component.

  Evidence links retain source provenance separately so canonical identity can
  survive collector retries, source changes, and later reconciliation findings.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(cpu memory disk)
  @statuses ~w(present missing unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "actual_components" do
    field :kind, :string
    field :status, :string, default: "present"
    field :name, :string
    field :model, :string
    field :slot, :string
    field :path, :string
    field :serial_number, :string
    field :part_number, :string
    field :attributes, :map, default: %{}
    field :metadata, :map, default: %{}
    field :first_observed_at, :utc_datetime_usec
    field :last_observed_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :owner_resource, Renga.Inventory.Resource
    has_many :evidence_matches, Renga.Catalog.ActualComponentEvidenceMatch
    timestamps()
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [
      :kind,
      :status,
      :name,
      :model,
      :slot,
      :path,
      :serial_number,
      :part_number,
      :attributes,
      :metadata,
      :first_observed_at,
      :last_observed_at
    ])
    |> trim_optional(:name)
    |> trim_optional(:model)
    |> trim_optional(:slot)
    |> trim_optional(:path)
    |> trim_optional(:serial_number)
    |> trim_optional(:part_number)
    |> validate_required([
      :organization_id,
      :owner_resource_id,
      :kind,
      :status,
      :first_observed_at,
      :last_observed_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_map(:attributes)
    |> validate_map(:metadata)
    |> validate_observation_order()
    |> assoc_constraint(:owner_resource, name: :actual_components_owner_resource_fkey)
    |> check_constraint(:kind, name: :actual_components_valid_kind)
    |> check_constraint(:status, name: :actual_components_valid_status)
    |> check_constraint(:last_observed_at, name: :actual_components_observation_order)
    |> unique_constraint(:serial_number, name: :actual_components_serial_identity_index)
  end

  defp validate_observation_order(changeset) do
    first = get_field(changeset, :first_observed_at)
    last = get_field(changeset, :last_observed_at)

    if first && last && DateTime.after?(first, last) do
      add_error(changeset, :last_observed_at, "must not precede first observation")
    else
      changeset
    end
  end

  defp trim_optional(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> empty_to_nil()
      value -> value
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
