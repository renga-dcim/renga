defmodule Renga.Repo.Migrations.ReserveExportCapacity do
  use Ecto.Migration

  def change do
    alter table(:organization_exports) do
      add :maximum_bytes, :bigint, null: false, default: 1_073_741_824
      add :storage, :text, null: false, default: "managed"
    end

    # Existing retained archives keep their charge even above the new default.
    execute(
      "UPDATE organization_exports SET maximum_bytes = GREATEST(maximum_bytes, COALESCE(bytes, 0))",
      "SELECT 1"
    )

    create constraint(:organization_exports, :export_capacity_bounds,
             check: "maximum_bytes > 0 AND (bytes IS NULL OR bytes BETWEEN 0 AND maximum_bytes)"
           )

    create constraint(:organization_exports, :export_storage,
             check: "storage IN ('managed', 'operator')"
           )
  end
end
