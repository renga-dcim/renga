defmodule Renga.Repo.Migrations.PreserveRetiredProviderScope do
  use Ecto.Migration

  def up do
    # A provider ID permanently reserves its original scope, even after the
    # tenant is purged. NULL would incorrectly turn it into deployment scope.
    drop constraint(:identity_providers, :identity_providers_organization_id_fkey)
  end

  def down do
    # Existing tombstones may name purged tenants; retain them on rollback.
    execute """
    ALTER TABLE identity_providers ADD CONSTRAINT identity_providers_organization_id_fkey
      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT NOT VALID
    """
  end
end
