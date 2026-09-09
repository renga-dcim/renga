defmodule Renga.Topology.TopologyFinding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "topology_findings" do
    field :kind, :string
    field :resolution_key, :string
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :last_observed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
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
      :last_observed_at,
      :resolved_at
    ])
    |> validate_required([
      :organization_id,
      :interface_id,
      :kind,
      :resolution_key,
      :status,
      :message,
      :details,
      :last_observed_at
    ])
    |> validate_inclusion(:status, ~w(open resolved))
    |> assoc_constraint(:interface, name: :topology_findings_tenant_interface_fkey)
    |> check_constraint(:resolved_at, name: :topology_findings_resolution_state)
    |> unique_constraint([:organization_id, :interface_id, :kind, :resolution_key],
      name: :topology_findings_open_resolution_index
    )
  end
end
