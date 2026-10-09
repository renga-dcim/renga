defmodule Renga.Catalog.ConfirmedComponent do
  @moduledoc """
  A replacement part someone confirmed installing in one slot of a resource
  (RFD 8, "Editing hardware components").

  The confirmed part number, serial, and model become what the slot
  expects, through `Renga.Catalog.ComponentMatch.with_confirmation/2`, so
  the part the operator installed is not drift. The confirmation never
  closes a finding by itself: a collector has to report the part first.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "confirmed_components" do
    field :part_number, :string
    field :serial_number, :string
    field :model, :string
    field :note, :string
    field :confirmed_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :hardware_assignment, Renga.Catalog.HardwareAssignment
    belongs_to :component_template, Renga.Catalog.ComponentTemplate
    belongs_to :exception, Renga.Catalog.ExpectedComponentException
    belongs_to :confirmed_by_user, Renga.Accounts.User

    timestamps()
  end

  @part_fields ~w(part_number serial_number model)a

  def changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, @part_fields ++ [:note])
    |> update_change(:part_number, &trim/1)
    |> update_change(:serial_number, &trim/1)
    |> update_change(:model, &trim/1)
    |> update_change(:note, &trim/1)
    |> validate_length(:part_number, max: 255)
    |> validate_length(:serial_number, max: 255)
    |> validate_length(:model, max: 255)
    |> validate_length(:note, max: 500)
    |> validate_identifies_part()
    |> validate_required([:organization_id, :hardware_assignment_id, :confirmed_at])
    |> check_constraint(:part_number,
      name: :confirmed_components_identifies_part,
      message: "enter a part number, serial, or model"
    )
  end

  defp validate_identifies_part(changeset) do
    if Enum.any?(@part_fields, &(get_field(changeset, &1) not in [nil, ""])),
      do: changeset,
      else: add_error(changeset, :part_number, "enter a part number, serial, or model")
  end

  defp trim(nil), do: nil

  defp trim(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
