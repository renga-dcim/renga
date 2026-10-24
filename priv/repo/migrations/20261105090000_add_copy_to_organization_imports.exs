defmodule Renga.Repo.Migrations.AddCopyToOrganizationImports do
  use Ecto.Migration

  # An import that gave every record a new ID (RFD 20), so links to the
  # source's records do not carry over.
  def change do
    alter table(:organization_imports) do
      add :copy, :boolean, null: false, default: false
    end
  end
end
