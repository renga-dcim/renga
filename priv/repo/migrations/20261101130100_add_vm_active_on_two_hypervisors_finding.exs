defmodule Renga.Repo.Migrations.AddVmActiveOnTwoHypervisorsFinding do
  use Ecto.Migration

  # RFD 11, "Findings": a VM that competing fresh libvirt evidence places on
  # more than one hypervisor. It is about the VM, whichever installations
  # report its hypervisors, so it names no agent.
  def up do
    alter table(:collector_findings) do
      modify :agent_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    valid_constraint(
      ~w(installation_key_changed possible_same_machine target_unreachable vm_active_on_two_hypervisors),
      "AND (kind = 'vm_active_on_two_hypervisors') = (agent_id IS NULL)"
    )
  end

  # The narrower constraints cannot hold these findings, so rolling back
  # discards them and the workflows people added to them.
  def down do
    execute(
      "DELETE FROM finding_workflows WHERE domain = 'collector' " <>
        "AND kind = 'vm_active_on_two_hypervisors'"
    )

    execute("DELETE FROM collector_findings WHERE kind = 'vm_active_on_two_hypervisors'")
    valid_constraint(~w(installation_key_changed possible_same_machine target_unreachable), "")

    alter table(:collector_findings) do
      modify :agent_id, :binary_id, null: false, from: {:binary_id, null: true}
    end
  end

  defp valid_constraint(kinds, extra) do
    drop constraint(:collector_findings, :collector_findings_valid)

    create constraint(:collector_findings, :collector_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
             AND (kind = 'target_unreachable') = (target_id IS NOT NULL)
             #{extra}
             """
           )
  end
end
