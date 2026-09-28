defmodule Renga.Topology.CableImportContract do
  @moduledoc """
  Manager-granted trust for one source to import confirmed cabling.

  Organization membership of a source is provenance, not trust: an imported
  claim becomes authoritative current cabling, so a manager must grant the
  source an explicit contract before `Renga.Topology.import_cable_assertion/3`
  accepts it. Revocation only stops new imports; retained assertions and the
  reconciled cable stay valid until an authorized retraction removes them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "cable_import_contracts" do
    field :granted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
    belongs_to :granted_by, Renga.Accounts.User
    belongs_to :revoked_by, Renga.Accounts.User
    timestamps()
  end

  @doc false
  # Attribution and timestamps are programmatic: only the grant/revoke APIs set
  # them, so the changeset casts nothing and exists for validation and
  # constraint mapping.
  def changeset(contract, attrs) do
    contract
    |> cast(attrs, [])
    |> validate_required([:organization_id, :source_id, :granted_at])
    |> assoc_constraint(:source, name: :cable_import_contracts_tenant_source_fkey)
    |> unique_constraint([:organization_id, :source_id],
      name: :cable_import_contracts_source_index
    )
  end
end
