defmodule Renga.Repo.Migrations.CreateOrganizationSecuritySettings do
  use Ecto.Migration

  # RFD 19, "Security settings": the organization settings its owners turn
  # on. A setting without a row has its default. Each row keeps who last
  # changed it, for the settings page; Activity keeps every change.
  def change do
    create table(:organization_security_settings) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :value, :map, null: false
      add :changed_by_user_id, references(:users, on_delete: :nilify_all)
      add :changed_by, :string, null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:organization_security_settings, [:organization_id, :name])
    create index(:organization_security_settings, [:changed_by_user_id])
  end
end
