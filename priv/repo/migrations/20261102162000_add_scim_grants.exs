defmodule Renga.Repo.Migrations.AddScimGrants do
  use Ecto.Migration

  # RFD 16 membership grants. A membership a SCIM connection created names
  # that connection; one granted by hand names none and SCIM never changes
  # it. A directory group may map to a built-in role, by its stable id.
  def change do
    alter table(:organization_memberships) do
      add :scim_connection_id,
          references(:scim_connections, type: :binary_id, on_delete: :nothing)
    end

    create index(:organization_memberships, [:scim_connection_id],
             where: "scim_connection_id IS NOT NULL"
           )

    alter table(:scim_groups) do
      add :role, :string
    end

    create constraint(:scim_groups, :scim_groups_role,
             check: "role IN ('owner', 'admin', 'member', 'viewer')"
           )
  end
end
