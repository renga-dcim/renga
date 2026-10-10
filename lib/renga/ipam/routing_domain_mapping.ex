defmodule Renga.IPAM.RoutingDomainMapping do
  @moduledoc """
  An organization's explicit mapping of one source's routing-domain key to a
  managed VRF, or to the global table when `vrf_id` is nil (RFD 4,
  "Observation correlation"). Keys compare case-insensitively, as VRF names
  do, and an explicit mapping wins over every automatic one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "source_routing_domain_mappings" do
    field :source_local_key, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
    belongs_to :vrf, Renga.IPAM.Vrf
    belongs_to :created_by, Renga.Accounts.User

    timestamps()
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:source_local_key, :vrf_id])
    |> update_change(:source_local_key, &String.trim/1)
    |> validate_required([:organization_id, :source_id, :source_local_key])
    |> validate_length(:source_local_key, max: 255, count: :codepoints)
    |> assoc_constraint(:source, name: :source_routing_domain_mappings_tenant_source_fkey)
    |> foreign_key_constraint(:vrf_id, name: :source_routing_domain_mappings_tenant_vrf_fkey)
    |> unique_constraint(:source_local_key,
      name: :source_routing_domain_mappings_source_key_index,
      message: "is already mapped for this source"
    )
  end
end
