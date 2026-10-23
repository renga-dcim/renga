defmodule Renga.Repo.Migrations.CreatePowerCorrelationSamples do
  use Ecto.Migration

  @kinds ~w(not_redundant feed_near_capacity supply_failed unexpected_draw path_incomplete)

  # RFD 10 "Suggested connections": the bounded correlation window, kept
  # apart from the current-reading projection and any chart store. It holds
  # outlet and supply-input samples only, at most one per series per
  # minute, for 24 hours. Suggestions join the Power Inbox domain.
  def change do
    create table(:power_correlation_samples, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_correlation_samples_tenant_source_fkey
          ),
          null: false

      add :target, :string
      add :sensor, :string, null: false
      add :boundary, :string, null: false
      add :quantity, :string, null: false
      add :component_kind, :string
      add :component_name, :string
      add :minute, :"timestamp(0)", null: false
      add :event_at, :"timestamp(3)", null: false
      add :value, :decimal
      add :state, :string
    end

    create unique_index(
             :power_correlation_samples,
             [:source_id, :target, :sensor, :boundary, :quantity, :minute],
             nulls_distinct: false,
             name: :power_correlation_samples_series_minute_index
           )

    create index(:power_correlation_samples, [:organization_id, :source_id, :target, :minute])

    create constraint(:power_correlation_samples, :power_correlation_samples_kind,
             check: """
             (boundary = 'outlet' AND component_kind = 'power_outlet'
              AND quantity IN ('real_power', 'current', 'state'))
             OR (boundary = 'supply_input' AND quantity IN ('real_power', 'state'))
             """
           )

    # Only valid evidence is kept, so a failed read is a gap, never zero.
    create constraint(:power_correlation_samples, :power_correlation_samples_value,
             check: "(quantity = 'state') = (state IS NOT NULL AND value IS NULL)"
           )

    execute(
      fn -> repo().query!(finding_kinds(@kinds ++ ["suggested_connection"])) end,
      fn ->
        repo().query!("DELETE FROM power_findings WHERE kind = 'suggested_connection'")
        repo().query!(finding_kinds(@kinds))
      end
    )
  end

  defp finding_kinds(kinds) do
    """
    ALTER TABLE power_findings
      DROP CONSTRAINT power_findings_valid,
      ADD CONSTRAINT power_findings_valid CHECK (
        status IN ('open', 'resolved')
        AND (status = 'resolved') = (resolved_at IS NOT NULL)
        AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
      )
    """
  end
end
