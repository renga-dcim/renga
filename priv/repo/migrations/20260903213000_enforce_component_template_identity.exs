defmodule Renga.Repo.Migrations.EnforceComponentTemplateIdentity do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM component_templates
        GROUP BY organization_id, catalog_type_revision_id, kind, lower(name)
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'component template identities conflict without regard to case';
      END IF;
    END
    $$
    """

    drop_if_exists unique_index(:component_templates, [
                     :organization_id,
                     :catalog_type_revision_id,
                     :kind,
                     :name
                   ])

    create unique_index(
             :component_templates,
             ["organization_id", "catalog_type_revision_id", "kind", "lower(name)"],
             name: :component_templates_identity_index
           )
  end

  def down do
    drop unique_index(:component_templates, [], name: :component_templates_identity_index)

    create unique_index(:component_templates, [
             :organization_id,
             :catalog_type_revision_id,
             :kind,
             :name
           ])
  end
end
