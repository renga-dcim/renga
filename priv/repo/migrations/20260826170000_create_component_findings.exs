defmodule Renga.Repo.Migrations.CreateComponentFindings do
  use Ecto.Migration

  def change do
    create table(:component_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :component_findings_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :resolution_key, :string, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :resolved_at, :"timestamp(3)"
      add :last_observed_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :component_findings,
             [:organization_id, :resource_id, :kind, :resolution_key],
             where: "status = 'open'",
             name: :component_findings_open_resolution_index
           )

    create index(:component_findings, [:organization_id, :resource_id, :status],
             name: :component_findings_resource_status_index
           )

    create constraint(:component_findings, :component_findings_valid_kind,
             check: """
             kind IN ('ambiguous_component_identity', 'ambiguous_expected_component',
               'unexpected_actual_component', 'component_drift', 'missing_expected_component')
             """
           )

    create constraint(:component_findings, :component_findings_valid_status,
             check: "status IN ('open', 'resolved')"
           )

    create constraint(:component_findings, :component_findings_resolution_state,
             check: """
             (status = 'open' AND resolved_at IS NULL) OR
               (status = 'resolved' AND resolved_at IS NOT NULL)
             """
           )
  end
end
