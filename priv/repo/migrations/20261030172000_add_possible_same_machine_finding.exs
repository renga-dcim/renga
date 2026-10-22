defmodule Renga.Repo.Migrations.AddPossibleSameMachineFinding do
  use Ecto.Migration

  # RFD 11, "Virtualization collection": a guest without a usable SMBIOS UUID
  # whose MAC addresses cover exactly one fresh libvirt domain.
  def up, do: kinds(~w(installation_key_changed possible_same_machine))

  # The narrower constraint cannot hold these findings, so rolling back
  # discards them and the workflows people added to them.
  def down do
    execute(
      "DELETE FROM finding_workflows WHERE domain = 'collector' AND kind = 'possible_same_machine'"
    )

    execute("DELETE FROM collector_findings WHERE kind = 'possible_same_machine'")
    kinds(~w(installation_key_changed))
  end

  defp kinds(kinds) do
    drop constraint(:collector_findings, :collector_findings_valid)

    create constraint(:collector_findings, :collector_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
             """
           )
  end
end
