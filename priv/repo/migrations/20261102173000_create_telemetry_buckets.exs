defmodule Renga.Repo.Migrations.CreateTelemetryBuckets do
  use Ecto.Migration

  # RFD 10 "Measured history": the built-in telemetry store keeps five-minute
  # buckets per organization and series, for 30 days. A bucket holds enough
  # to merge into wider buckets (count, sum, minimum, maximum, and the last
  # sample), so a write folds into its bucket and raw samples are never kept.
  def change do
    create table(:telemetry_buckets, primary_key: false) do
      add :organization_id,
          references(:organizations, on_delete: :delete_all, type: :binary_id),
          null: false,
          primary_key: true

      add :series, :string, null: false, primary_key: true
      add :bucket_start, :"timestamp(0)", null: false, primary_key: true
      add :count, :integer, null: false
      add :sum, :float, null: false
      add :minimum, :float, null: false
      add :maximum, :float, null: false
      add :last_value, :float, null: false
      add :last_at, :"timestamp(3)", null: false
    end

    create index(:telemetry_buckets, [:bucket_start])

    create constraint(:telemetry_buckets, :telemetry_buckets_aligned,
             check: "mod(extract(epoch FROM bucket_start)::bigint, 300) = 0"
           )

    create constraint(:telemetry_buckets, :telemetry_buckets_count, check: "count > 0")
  end
end
