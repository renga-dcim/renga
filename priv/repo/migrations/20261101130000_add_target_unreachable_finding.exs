defmodule Renga.Repo.Migrations.AddTargetUnreachableFinding do
  use Ecto.Migration

  # RFD 11, "Findings": a configured switch or hypervisor that has not
  # answered for longer than its freshness window. One stream can reach one
  # switch through several targets, so these findings are kept apart per
  # target; other collector findings have none.
  def up do
    create unique_index(:collector_targets, [:id, :organization_id])

    alter table(:collector_findings) do
      add :target_id,
          references(:collector_targets,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :collector_findings_organization_target_fkey
          )
    end

    drop index(:collector_findings, [:organization_id, :resource_id, :agent_id, :kind],
           name: :collector_findings_open_index
         )

    create unique_index(
             :collector_findings,
             [:organization_id, :resource_id, :agent_id, :kind, :target_id],
             where: "status = 'open'",
             nulls_distinct: false,
             name: :collector_findings_open_index
           )

    valid_constraint(
      ~w(installation_key_changed possible_same_machine target_unreachable),
      "AND (kind = 'target_unreachable') = (target_id IS NOT NULL)"
    )
  end

  # The narrower constraint cannot hold these findings, so rolling back
  # discards them and the workflows people added to them.
  def down do
    execute(
      "DELETE FROM finding_workflows WHERE domain = 'collector' AND kind = 'target_unreachable'"
    )

    execute("DELETE FROM collector_findings WHERE kind = 'target_unreachable'")
    valid_constraint(~w(installation_key_changed possible_same_machine), "")

    drop index(
           :collector_findings,
           [:organization_id, :resource_id, :agent_id, :kind, :target_id],
           name: :collector_findings_open_index
         )

    create unique_index(:collector_findings, [:organization_id, :resource_id, :agent_id, :kind],
             where: "status = 'open'",
             name: :collector_findings_open_index
           )

    alter table(:collector_findings) do
      remove :target_id
    end

    drop index(:collector_targets, [:id, :organization_id])
  end

  defp valid_constraint(kinds, extra) do
    drop constraint(:collector_findings, :collector_findings_valid)

    create constraint(:collector_findings, :collector_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
             #{extra}
             """
           )
  end
end
