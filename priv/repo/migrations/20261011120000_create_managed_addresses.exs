defmodule Renga.Repo.Migrations.CreateManagedAddresses do
  @moduledoc """
  Addresses an operator adopted into managed state (RFD 8, "Prefixes").

  Observed addresses stay normal without a managed row; adopting one records
  intent that outlives the observation. The interface is optional and only
  remembers where the address was adopted from, so deleting the interface
  keeps the managed address.
  """

  use Ecto.Migration

  def change do
    create table(:managed_addresses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :address, :inet, null: false
      add :description, :string

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:interface_id]},
            type: :binary_id,
            name: :managed_addresses_tenant_interface_fkey
          )

      add :adopted_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:managed_addresses, [:organization_id, :address],
             name: :managed_addresses_organization_address_index
           )

    # Managed identity is a host, independent of the collector's interface mask.
    create constraint(:managed_addresses, :managed_addresses_host_address,
             check: "masklen(address) = CASE family(address) WHEN 4 THEN 32 ELSE 128 END"
           )

    create index(:managed_addresses, [:interface_id])
  end
end
