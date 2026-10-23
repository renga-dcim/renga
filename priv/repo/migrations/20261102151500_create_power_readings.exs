defmodule Renga.Repo.Migrations.CreatePowerReadings do
  use Ecto.Migration

  # RFD 10 phase 4: timed power readings arrive in versioned telemetry
  # batches, apart from inventory observations. A batch is accepted once per
  # source and replay ID. Each reading series keeps only its current value,
  # advanced by event time, so a replayed or delayed sample never replaces a
  # newer one. Invalid evidence is kept as such and never stored as zero.
  def up do
    # The RFD 10 collector modules report through their own streams.
    execute "ALTER TABLE sources DROP CONSTRAINT sources_collector_stream"

    create constraint(:sources, :sources_collector_stream,
             check: collector_stream_check(~w(switch_poller vm_provider power_poller bmc_power))
           )

    create table(:telemetry_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :telemetry_batches_tenant_source_fkey
          ),
          null: false

      add :replay_id, :string, null: false
      add :version, :integer, null: false
      add :payload_digest, :string, null: false
      add :sample_count, :integer, null: false
      add :received_at, :"timestamp(3)", null: false
    end

    create unique_index(:telemetry_batches, [:source_id, :replay_id])
    create index(:telemetry_batches, [:received_at])

    create table(:power_readings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_readings_tenant_source_fkey
          ),
          null: false

      # A collector's target key; a host agent's own readings have none.
      add :target, :string
      add :sensor, :string, null: false
      add :boundary, :string, null: false
      add :quantity, :string, null: false
      add :unit, :string
      add :window_ms, :integer, null: false
      add :leg, :string
      add :component_kind, :string
      add :component_name, :string
      add :coverage, :string
      add :origin, :string, null: false
      add :mapping_name, :string, null: false
      add :mapping_version, :integer, null: false
      add :value, :decimal
      add :state, :string
      add :validity, :string, null: false
      add :window_start, :"timestamp(3)", null: false
      add :window_end, :"timestamp(3)", null: false
      add :event_at, :"timestamp(3)", null: false
      add :fresh_until, :"timestamp(3)", null: false
      add :received_at, :"timestamp(3)", null: false
    end

    # One current value per series. A rolling average and an instantaneous
    # value of the same sensor are different series.
    create unique_index(
             :power_readings,
             [:source_id, :target, :sensor, :boundary, :quantity, :window_ms],
             nulls_distinct: false,
             name: :power_readings_series_index
           )

    create index(:power_readings, [:organization_id, :source_id, :target])

    create constraint(:power_readings, :power_readings_vocabulary,
             check: """
             boundary IN ('host_input', 'supply_input', 'supply_output', 'outlet', 'feed', 'leg')
             AND quantity IN ('real_power', 'apparent_power', 'current', 'voltage', 'power_factor', 'state')
             AND validity IN ('valid', 'missing', 'failed', 'invalid')
             AND origin IN ('native', 'exporter')
             AND (coverage IS NULL OR coverage IN ('complete', 'partial'))
             AND (leg IS NULL OR leg IN ('a', 'b', 'c'))
             AND (component_kind IS NULL OR component_kind IN ('power_port', 'power_outlet'))
             AND (component_kind IS NULL) = (component_name IS NULL)
             """
           )

    # Only valid evidence carries a value, and a state only for `state`.
    create constraint(:power_readings, :power_readings_value,
             check: """
             (validity = 'valid') = (value IS NOT NULL OR state IS NOT NULL)
             AND (value IS NULL OR quantity <> 'state')
             AND (state IS NULL OR quantity = 'state')
             """
           )

    create constraint(:power_readings, :power_readings_window,
             check: """
             window_start <= window_end AND window_ms >= 0 AND fresh_until > event_at
             """
           )
  end

  def down do
    drop table(:power_readings)
    drop table(:telemetry_batches)

    # The widened collector stream check stays: a power poller's or BMC
    # collector's source outlives these tables, and keeping it is safer than
    # deleting that provenance or failing the rollback on it.
  end

  defp collector_stream_check(kinds) do
    kinds = Enum.map_join(kinds, ", ", &"'#{&1}'")

    """
    (collector_id IS NULL AND agent_id IS NULL)
    OR
    (collector_id IS NOT NULL AND agent_id IS NOT NULL
     AND kind IN (#{kinds}))
    """
  end
end
