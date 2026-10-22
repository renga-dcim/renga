defmodule Renga.Repo.Migrations.CreateOrganizationLimits do
  use Ecto.Migration

  # RFD 21: an operator's per-organization overrides of deployment-wide limit
  # defaults. RFD 22's policy document will read and write the same rows.
  def change do
    create table(:organization_limits) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :value, :bigint, null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:organization_limits, [:organization_id, :name])
    create constraint(:organization_limits, :value_not_negative, check: "value >= 0")
  end
end
