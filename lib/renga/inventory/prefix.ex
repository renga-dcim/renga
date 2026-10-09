defmodule Renga.Inventory.Prefix do
  @moduledoc """
  Typed canonical IPAM prefix projection backed by PostgreSQL `cidr`.

  Prefix containment and overlap remain database operations rather than string
  parsing, while the associated resource envelope carries desired state.

  A routing table holds one prefix per CIDR. The table is a VRF, or the
  global table when `vrf_id` is nil (RFD 4, "VRFs"); the composite foreign
  key keeps a prefix from naming another organization's VRF.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource
  alias Renga.Types.Cidr

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(container active reserved deprecated)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "prefixes" do
    field :prefix, Cidr
    field :status, :string, default: "active"
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :vrf, Renga.IPAM.Vrf

    timestamps()
  end

  def changeset(prefix, attrs) do
    prefix
    |> cast(attrs, [:prefix, :vrf_id, :status, :description, :metadata])
    |> validate_required([:organization_id, :resource_id, :prefix, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :prefixes_organization_resource_fkey)
    |> foreign_key_constraint(:vrf_id, name: :prefixes_tenant_vrf_fkey)
    |> unique_constraint([:organization_id, :resource_id])
    |> unique_constraint(:prefix,
      name: :prefixes_organization_vrf_prefix_index,
      message: "already exists in this routing table"
    )
    |> check_constraint(:status, name: :prefixes_valid_status)
  end

  def statuses, do: @statuses
end
