defmodule Renga.Catalog.ExpectedComponentException do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(interface module_bay power_port power_outlet console_port device_bay)

  schema "expected_component_exceptions" do
    field :action, :string
    field :kind, :string
    field :name, :string
    field :changes, :map, default: %{}
    field :confirmed_by_user_id, :binary_id
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :hardware_assignment, Renga.Catalog.HardwareAssignment
    belongs_to :component_template, Renga.Catalog.ComponentTemplate
    timestamps()
  end

  def changeset(exception, attrs) do
    exception
    |> cast(attrs, [:component_template_id, :action, :kind, :name, :changes])
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :organization_id,
      :hardware_assignment_id,
      :action,
      :confirmed_by_user_id
    ])
    |> validate_inclusion(:action, ~w(add suppress alter))
    |> validate_inclusion(:kind, @kinds)
    |> validate_shape()
    |> assoc_constraint(:hardware_assignment,
      name: :expected_component_exceptions_assignment_fkey
    )
    |> assoc_constraint(:component_template,
      name: :expected_component_exceptions_template_fkey
    )
    |> unique_constraint([:organization_id, :hardware_assignment_id, :component_template_id],
      name: :expected_component_exceptions_template_index
    )
    |> check_constraint(:action, name: :expected_component_exceptions_valid_shape)
  end

  defp validate_shape(changeset) do
    case get_field(changeset, :action) do
      "add" ->
        validate_required(changeset, [:kind, :name])

      action when action in ~w(suppress alter) ->
        validate_required(changeset, [:component_template_id])

      _action ->
        changeset
    end
  end
end
