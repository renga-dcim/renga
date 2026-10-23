defmodule Renga.Repo.Migrations.UniqueScimGroupNames do
  use Ecto.Migration

  # Microsoft Entra ID matches groups by displayName and requires it to be
  # unique, so a connection's group names are unique without case, as
  # filters compare them. Role mappings still name the group's id.
  def change do
    drop index(:scim_groups, [:connection_id, :display_name])

    create unique_index(:scim_groups, ["connection_id", "lower(display_name)"],
             name: :scim_groups_connection_id_display_name_index
           )
  end
end
