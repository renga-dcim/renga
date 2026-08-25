defmodule Renga.Catalog.ModuleInstallationEvent do
  @moduledoc "Append-only history for current module installation transitions."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "module_installation_events" do
    field :sequence, :integer, read_after_writes: true
    field :action, :string
    field :occurred_at, :utc_datetime_usec
    field :actor_user_id, :binary_id
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :module_bay, Renga.Catalog.ModuleBay
    belongs_to :module, Renga.Catalog.Module
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :occurred_at, :metadata])
    |> validate_required([
      :organization_id,
      :module_bay_id,
      :module_id,
      :action,
      :occurred_at
    ])
    |> validate_inclusion(:action, ~w(installed removed))
    |> validate_map(:metadata)
    |> assoc_constraint(:module_bay, name: :module_installation_events_bay_fkey)
    |> assoc_constraint(:module, name: :module_installation_events_module_fkey)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
