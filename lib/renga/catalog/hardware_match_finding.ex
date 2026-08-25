defmodule Renga.Catalog.HardwareMatchFinding do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "hardware_match_findings" do
    field :kind, :string
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :resolved_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    timestamps()
  end

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:kind, :status, :message, :details, :resolved_at])
    |> validate_required([:organization_id, :resource_id, :kind, :status, :message])
    |> validate_inclusion(:kind, ~w(ambiguous_catalog_match))
    |> validate_inclusion(:status, ~w(open resolved))
    |> assoc_constraint(:resource, name: :hardware_match_findings_resource_fkey)
    |> unique_constraint([:organization_id, :resource_id, :kind],
      name: :hardware_match_findings_open_kind_index
    )
  end
end
