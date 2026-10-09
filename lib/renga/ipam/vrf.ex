defmodule Renga.IPAM.Vrf do
  @moduledoc """
  An optional routing namespace (RFD 4, "VRFs").

  A prefix with no VRF belongs to the global routing table, which is a real
  namespace rather than a missing value; there is no "default" VRF row. A
  VRF is the typed projection of a `vrf` resource envelope. Names are unique
  per organization regardless of case, so `Blue` and `blue` cannot become
  two namespaces again, and a route distinguisher, when set, is unique too.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active deprecated)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "vrfs" do
    field :name, :string
    field :route_distinguisher, :string
    field :status, :string, default: "active"
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource

    timestamps()
  end

  def changeset(vrf, attrs) do
    vrf
    |> cast(attrs, [:name, :route_distinguisher, :status, :description])
    |> update_change(:name, &String.trim/1)
    |> update_change(:route_distinguisher, &String.trim/1)
    |> validate_required([:organization_id, :resource_id, :name, :status])
    |> validate_length(:name, max: 100)
    |> validate_name()
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:resource, name: :vrfs_organization_resource_fkey)
    |> unique_constraint(:name,
      name: :vrfs_organization_name_index,
      message: "is already a VRF in this organization"
    )
    |> unique_constraint(:route_distinguisher,
      name: :vrfs_organization_route_distinguisher_index,
      message: "is already used by another VRF"
    )
    |> check_constraint(:status, name: :vrfs_valid_status)
  end

  def statuses, do: @statuses

  # Legacy `default` tables became the global table, which has no row, so a
  # VRF cannot take that name back.
  defp validate_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if String.downcase(name) == "default",
        do: [name: "is reserved for the global routing table"],
        else: []
    end)
  end
end
