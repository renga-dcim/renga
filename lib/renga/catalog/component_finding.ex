defmodule Renga.Catalog.ComponentFinding do
  @moduledoc "Expected-versus-observed component reconciliation finding."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(ambiguous_component_identity ambiguous_expected_component unexpected_actual_component component_drift missing_expected_component module_bay_not_found ambiguous_module_bay module_type_not_found ambiguous_module_type incompatible_module_type)
  @statuses ~w(open resolved)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "component_findings" do
    field :kind, :string
    field :resolution_key, :string
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :resolved_at, :utc_datetime_usec
    field :last_observed_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    timestamps()
  end

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :kind,
      :resolution_key,
      :status,
      :message,
      :details,
      :resolved_at,
      :last_observed_at
    ])
    |> validate_required([
      :organization_id,
      :resource_id,
      :kind,
      :resolution_key,
      :status,
      :message,
      :last_observed_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_map(:details)
    |> assoc_constraint(:resource, name: :component_findings_resource_fkey)
    |> check_constraint(:resolved_at,
      name: :component_findings_resolution_state,
      message: "must agree with finding status"
    )
    |> unique_constraint([:organization_id, :resource_id, :kind, :resolution_key],
      name: :component_findings_open_resolution_index
    )
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
