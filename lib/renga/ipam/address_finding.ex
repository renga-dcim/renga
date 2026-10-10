defmodule Renga.IPAM.AddressFinding do
  @moduledoc """
  One address finding (RFD 4, "Findings"): a condition reconciliation
  observes about an address on one interface.

  `kind` is one of `kinds/0`. The finding belongs to the interface the
  address is observed or assigned on, and `resolution_key` names the address
  there (its host, prefixed with its VRF outside the global table; the
  managed address for a stale or wrong-VRF assignment; or the source and key
  of an unmapped routing domain), so the
  finding's identity survives a mask change and its workflow follows a
  recurrence. `details` keep the involved records and source evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @kinds ~w(unmanaged_in_strict_prefix outside_prefix stale_managed_assignment duplicate_address prefix_length_mismatch wrong_vrf unmapped_routing_domain)

  schema "address_findings" do
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

  def kinds, do: @kinds

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
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, ~w(open resolved))
    |> assoc_constraint(:interface, name: :address_findings_tenant_interface_fkey)
    |> check_constraint(:resolved_at, name: :address_findings_resolution_state)
    |> unique_constraint([:organization_id, :interface_id, :kind, :resolution_key],
      name: :address_findings_open_resolution_index
    )
  end
end
