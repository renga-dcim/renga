defmodule Renga.Repo.Migrations.AddPossibleSameMachineFinding do
  use Ecto.Migration

  # RFD 11, "Virtualization collection": a guest without a usable SMBIOS UUID
  # whose MAC addresses cover exactly one fresh libvirt domain.
  def up, do: kinds(~w(installation_key_changed possible_same_machine))
  def down, do: kinds(~w(installation_key_changed))

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
