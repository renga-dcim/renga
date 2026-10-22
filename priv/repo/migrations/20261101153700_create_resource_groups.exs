defmodule Renga.Repo.Migrations.CreateResourceGroups do
  @moduledoc """
  RFD 18 resource groups: named sets of resources that people curate, for
  access boundaries that cut across sites and teams (environment, customer,
  compliance scope).

  * `resource_group_sets` group the groups, such as `Environment`; an
    exclusive set lets a resource belong to at most one of its groups.
  * `resource_groups` belong to at most one set.
  * `resource_group_members` are direct memberships, which only people
    change.
  * `resource_group_memberships` materialize effective membership: one row
    per resource, authorization view, and group, deduplicated across every
    path that supplies it. A row for a group in an exclusive set carries the
    set's id, and a partial unique index allows one such row per resource,
    view, and set, so the database itself refuses a conflicting write.
  """

  use Ecto.Migration

  def change do
    create table(:resource_group_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :exclusive, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:resource_group_sets, [:organization_id, "lower(name)"],
             name: :resource_group_sets_organization_name_index
           )

    create unique_index(:resource_group_sets, [:id, :organization_id])

    create table(:resource_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :group_set_id,
          references(:resource_group_sets,
            with: [organization_id: :organization_id],
            # Deleting a set keeps its groups, outside any set.
            on_delete: {:nilify, [:group_set_id]},
            type: :binary_id,
            name: :resource_groups_tenant_group_set_fkey
          )

      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:resource_groups, [:organization_id, "lower(name)"],
             name: :resource_groups_organization_name_index
           )

    create unique_index(:resource_groups, [:id, :organization_id])
    create index(:resource_groups, [:group_set_id])

    create table(:resource_group_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :group_id,
          references(:resource_groups,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_members_tenant_group_fkey
          ),
          null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_members_tenant_resource_fkey
          ),
          null: false

      add :added_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:resource_group_members, [:group_id, :resource_id])
    create index(:resource_group_members, [:organization_id, :resource_id])

    create table(:resource_group_memberships, primary_key: false) do
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false,
        primary_key: true

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_memberships_tenant_resource_fkey
          ),
          null: false,
          primary_key: true

      add :view, :string, null: false, primary_key: true

      add :group_id,
          references(:resource_groups,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_memberships_tenant_group_fkey
          ),
          null: false,
          primary_key: true

      # Set only while the group's set is exclusive.
      add :group_set_id,
          references(:resource_group_sets,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:group_set_id]},
            type: :binary_id,
            name: :resource_group_memberships_tenant_group_set_fkey
          )
    end

    create constraint(:resource_group_memberships, :resource_group_memberships_view,
             check: "view IN ('inventory', 'trusted')"
           )

    create unique_index(
             :resource_group_memberships,
             [:organization_id, :resource_id, :view, :group_set_id],
             where: "group_set_id IS NOT NULL",
             name: :resource_group_memberships_exclusive_index
           )

    create index(:resource_group_memberships, [:group_id, :view])
  end
end
