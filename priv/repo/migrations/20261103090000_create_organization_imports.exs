defmodule Renga.Repo.Migrations.CreateOrganizationImports do
  use Ecto.Migration

  # RFD 20: importing an organization's archive into an empty organization.
  def change do
    # One row per import that landed, naming the archive it came from.
    create table(:organization_imports) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :source_organization_id, :binary_id, null: false
      add :source_slug, :string, null: false
      add :source_name, :string, null: false
      add :format_version, :integer, null: false
      add :renga_version, :string, null: false
      add :snapshot_at, :"timestamp(3)", null: false
      add :parts, {:array, :string}, null: false, default: []
      add :records, :bigint, null: false
      add :sha256, :string, null: false
      # The source's settings as exported, including any held back for an
      # owner to confirm.
      add :source_settings, :map, null: false, default: %{}
      add :held_settings, :map, null: false, default: %{}
      add :imported_by_user_id, references(:users, on_delete: :nilify_all)
      add :operator, :string

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:organization_imports, [:organization_id])

    # The people the archive names. A principal is attribution only until it
    # is linked to a destination account.
    create table(:imported_principals) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      add :organization_import_id, references(:organization_imports, on_delete: :delete_all),
        null: false

      add :source_id, :binary_id, null: false
      add :email, :citext
      add :user_id, references(:users, on_delete: :nilify_all)
      add :linked_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:imported_principals, [:organization_id, :source_id])
    create unique_index(:imported_principals, [:id, :organization_id])

    # Which principal an imported record's person field named. The field
    # itself stays empty until the principal is linked.
    create table(:imported_attributions, primary_key: false) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :record_type, :string, null: false, primary_key: true
      add :record_id, :binary_id, null: false, primary_key: true
      add :field, :string, null: false, primary_key: true

      add :principal_id,
          references(:imported_principals,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:imported_attributions, [:principal_id])

    # Records that only apply once their principal is linked, such as
    # memberships and private saved views, kept as the archive had them.
    create table(:imported_held_records) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      add :principal_id,
          references(:imported_principals,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          null: false

      add :record_type, :string, null: false
      add :record, :map, null: false
    end

    create index(:imported_held_records, [:principal_id])

    # Imported jobs are history: they never lease, retry, or run.
    alter table(:jobs) do
      add :imported_at, :"timestamp(3)"
    end

    execute(
      """
      CREATE FUNCTION reject_imported_job_update() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'imported jobs are history and cannot change'
          USING ERRCODE = '23514', CONSTRAINT = 'jobs_imported_immutable';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION reject_imported_job_update()"
    )

    execute(
      """
      CREATE TRIGGER jobs_reject_imported_update
      BEFORE UPDATE ON jobs
      FOR EACH ROW WHEN (OLD.imported_at IS NOT NULL)
      EXECUTE FUNCTION reject_imported_job_update()
      """,
      "DROP TRIGGER jobs_reject_imported_update ON jobs"
    )

    # An imported binding is not approved at the destination.
    execute(
      """
      ALTER TABLE target_bindings DROP CONSTRAINT target_bindings_valid,
      ADD CONSTRAINT target_bindings_valid CHECK (#{binding_check(~w(replaced revoked key_replaced imported))})
      """,
      """
      ALTER TABLE target_bindings DROP CONSTRAINT target_bindings_valid,
      ADD CONSTRAINT target_bindings_valid CHECK (#{binding_check(~w(replaced revoked key_replaced))})
      """
    )

    # Where a record must name the person behind it, an imported record
    # names their principal until it is linked.
    for table <- [:expected_component_exceptions, :desired_module_assignments] do
      alter table(table) do
        add :confirmed_by_principal_id,
            references(:imported_principals,
              with: [organization_id: :organization_id],
              on_delete: :restrict
            )
      end

      execute(
        "ALTER TABLE #{table} ALTER COLUMN confirmed_by_user_id DROP NOT NULL",
        "ALTER TABLE #{table} ALTER COLUMN confirmed_by_user_id SET NOT NULL"
      )

      create constraint(table, :confirmed_by_someone,
               check: "confirmed_by_user_id IS NOT NULL OR confirmed_by_principal_id IS NOT NULL"
             )
    end

    alter table(:cable_assertions) do
      add :actor_principal_id,
          references(:imported_principals,
            with: [organization_id: :organization_id],
            on_delete: :restrict
          )
    end

    execute(
      """
      ALTER TABLE cable_assertions DROP CONSTRAINT cable_assertions_attribution_shape,
      ADD CONSTRAINT cable_assertions_attribution_shape CHECK (#{attribution_shape("(actor_user_id IS NOT NULL OR actor_principal_id IS NOT NULL)")})
      """,
      """
      ALTER TABLE cable_assertions DROP CONSTRAINT cable_assertions_attribution_shape,
      ADD CONSTRAINT cable_assertions_attribution_shape CHECK (#{attribution_shape("actor_user_id IS NOT NULL")})
      """
    )

    # Last, so rolling back checks it first: without imported_at and its
    # trigger, imported jobs would lease and run as ordinary work.
    execute(
      "SELECT 1",
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM organization_imports) THEN
          RAISE EXCEPTION 'organizations were imported; remove them before rolling back this migration';
        END IF;
      END
      $$
      """
    )
  end

  # An operator's cable claim names who made it; an import or neighbor
  # evidence names its source instead.
  defp attribution_shape(operator_actor) do
    """
    ((kind = 'operator' AND #{operator_actor}
      AND source_id IS NULL AND interface_neighbor_evidence_id IS NULL)
     OR (kind = 'import' AND actor_user_id IS NULL
      AND source_id IS NOT NULL AND interface_neighbor_evidence_id IS NULL)
     OR (kind = 'neighbor_evidence' AND actor_user_id IS NULL
      AND source_id IS NULL AND interface_neighbor_evidence_id IS NOT NULL)) IS TRUE
    """
  end

  defp binding_check(reasons) do
    """
    version > 0
    AND status IN ('active', 'revoked')
    AND (status = 'revoked') = (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL)
    AND (revoked_reason IS NULL OR revoked_reason IN (#{Enum.map_join(reasons, ", ", &"'#{&1}'")}))
    """
  end
end
