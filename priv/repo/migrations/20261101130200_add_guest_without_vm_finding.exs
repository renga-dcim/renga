defmodule Renga.Repo.Migrations.AddGuestWithoutVmFinding do
  use Ecto.Migration

  # RFD 11, "Findings": a KVM guest whose SMBIOS UUID matches no domain on
  # any reporting hypervisor. It would flag every guest on a hypervisor that
  # is not collected yet, so an organization opts in once every hypervisor
  # reports.
  def up do
    alter table(:organizations) do
      add :guest_without_vm_findings, :boolean, null: false, default: false
    end

    valid_constraint(
      ~w(installation_key_changed possible_same_machine target_unreachable vm_active_on_two_hypervisors guest_without_vm)
    )
  end

  # The narrower constraint cannot hold these findings, so rolling back
  # discards them and the workflows people added to them.
  def down do
    execute(
      "DELETE FROM finding_workflows WHERE domain = 'collector' AND kind = 'guest_without_vm'"
    )

    execute("DELETE FROM collector_findings WHERE kind = 'guest_without_vm'")

    valid_constraint(
      ~w(installation_key_changed possible_same_machine target_unreachable vm_active_on_two_hypervisors)
    )

    alter table(:organizations) do
      remove :guest_without_vm_findings
    end
  end

  defp valid_constraint(kinds) do
    drop constraint(:collector_findings, :collector_findings_valid)

    create constraint(:collector_findings, :collector_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
             AND (kind = 'target_unreachable') = (target_id IS NOT NULL)
             AND (kind = 'vm_active_on_two_hypervisors') = (agent_id IS NULL)
             """
           )
  end
end
