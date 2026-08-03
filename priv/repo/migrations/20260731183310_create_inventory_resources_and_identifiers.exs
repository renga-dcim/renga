defmodule Renga.Repo.Migrations.CreateInventoryResourcesAndIdentifiers do
  use Ecto.Migration

  def change do
    execute "CREATE SEQUENCE resource_revision_sequence AS bigint"

    create table(:resources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :display_name, :string
      add :lifecycle_state, :string, null: false, default: "unknown"
      add :spec, :map, null: false, default: %{}
      add :generation, :bigint, null: false, default: 1
      add :resource_version, :bigint, null: false
      add :labels, :map, null: false, default: %{}
      add :annotations, :map, null: false, default: %{}
      add :deletion_requested_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:resources, [:organization_id, :kind, :name])
    create index(:resources, [:organization_id, :kind])
    create index(:resources, [:organization_id, :lifecycle_state])
    create index(:resources, [:organization_id, :resource_version])
    create index(:resources, [:labels], using: :gin)

    create table(:hosts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :hostname, :string
      add :fqdn, :string
      add :vendor, :string
      add :model, :string
      add :asset_tag, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:hosts, [:organization_id, :resource_id])
    create index(:hosts, [:organization_id, :hostname])
    create index(:hosts, [:organization_id, :fqdn])
    create index(:hosts, [:organization_id, :asset_tag])

    create table(:resource_conditions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :type, :string, null: false
      add :status, :string, null: false
      add :reason, :string
      add :message, :text
      add :observed_generation, :bigint
      add :last_transition_at, :"timestamp(3)", null: false
      add :details, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:resource_conditions, [:organization_id, :resource_id, :type])
    create index(:resource_conditions, [:organization_id, :type, :status])

    create table(:resource_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :revision, :bigint, null: false
      add :action, :string, null: false
      add :generation, :bigint, null: false
      add :snapshot, :map, null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:resource_revisions, [:revision])
    create index(:resource_revisions, [:organization_id, :revision])
    create index(:resource_revisions, [:organization_id, :resource_id, :revision])

    create table(:resource_identifiers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :value, :string, null: false
      add :normalized_value, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create index(:resource_identifiers, [:organization_id, :resource_id])
    create index(:resource_identifiers, [:organization_id, :kind, :normalized_value])

    create unique_index(
             :resource_identifiers,
             [:organization_id, :resource_id, :kind, :normalized_value],
             name: :resource_identifiers_resource_kind_value_index
           )
  end
end
