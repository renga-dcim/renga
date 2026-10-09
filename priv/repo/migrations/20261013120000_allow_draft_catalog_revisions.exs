defmodule Renga.Repo.Migrations.AllowDraftCatalogRevisions do
  @moduledoc """
  Lets an unpublished catalog revision act as a draft (RFD 8, "Editing
  hardware components"): while `finalized_at` is null its fields can change
  and it can be discarded. Publishing still freezes it for good, and each
  type has at most one draft at a time.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION enforce_catalog_type_revision_immutability() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.finalized_at IS NULL
           OR NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
          RETURN OLD;
        END IF;
      ELSIF OLD.finalized_at IS NULL
            AND NEW.organization_id = OLD.organization_id
            AND NEW.hardware_type_id IS NOT DISTINCT FROM OLD.hardware_type_id
            AND NEW.module_type_id IS NOT DISTINCT FROM OLD.module_type_id THEN
        -- A draft may change freely; publishing changes nothing but finalized_at.
        IF NEW.finalized_at IS NULL
           OR (to_jsonb(NEW) - 'finalized_at') = (to_jsonb(OLD) - 'finalized_at') THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION 'catalog revisions are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'catalog_type_revisions_immutable';
    END;
    $$ LANGUAGE plpgsql
    """

    create unique_index(:catalog_type_revisions, [:organization_id, :hardware_type_id],
             where: "hardware_type_id IS NOT NULL AND finalized_at IS NULL",
             name: :catalog_type_revisions_one_hardware_draft_index
           )

    create unique_index(:catalog_type_revisions, [:organization_id, :module_type_id],
             where: "module_type_id IS NOT NULL AND finalized_at IS NULL",
             name: :catalog_type_revisions_one_module_draft_index
           )
  end

  def down do
    drop index(:catalog_type_revisions, [], name: :catalog_type_revisions_one_module_draft_index)

    drop index(:catalog_type_revisions, [],
           name: :catalog_type_revisions_one_hardware_draft_index
         )

    execute """
    CREATE OR REPLACE FUNCTION enforce_catalog_type_revision_immutability() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
          RETURN OLD;
        END IF;
      ELSIF OLD.finalized_at IS NULL
            AND NEW.finalized_at IS NOT NULL
            AND (to_jsonb(NEW) - 'finalized_at') = (to_jsonb(OLD) - 'finalized_at') THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'catalog revisions are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'catalog_type_revisions_immutable';
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
