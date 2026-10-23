defmodule Renga.Repo.Migrations.CreateTelemetryMarks do
  use Ecto.Migration

  # RFD 10 "Measured history": the last minute each periodic history writer
  # recorded for an organization. Every node runs the writers, and claiming
  # the minute here first means each minute is written once.
  def change do
    create table(:telemetry_marks, primary_key: false) do
      add :organization_id,
          references(:organizations, on_delete: :delete_all, type: :binary_id),
          null: false,
          primary_key: true

      add :name, :string, null: false, primary_key: true
      add :recorded_at, :"timestamp(0)", null: false
    end
  end
end
