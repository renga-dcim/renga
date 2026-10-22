defmodule Renga.Repo.Migrations.CreatePowerFindings do
  use Ecto.Migration

  # RFD 10 phase 4: power findings join the Inbox under a Power domain. A
  # finding is filed on the resource it is about: the device for redundancy,
  # supply, and path findings, the feed's envelope for capacity, and the PDU
  # for an outlet drawing power with nothing connected. `resolution_key`
  # tells apart findings of one kind on one resource, such as two ports.
  def change do
    create table(:power_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_findings_organization_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :resolution_key, :string, null: false, default: ""
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :last_observed_at, :"timestamp(3)", null: false
      add :resolved_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:power_findings, [:organization_id, :resource_id, :kind, :resolution_key],
             where: "status = 'open'",
             name: :power_findings_open_index
           )

    create index(:power_findings, [:organization_id, :status, :kind])

    create constraint(:power_findings, :power_findings_valid,
             check: """
             status IN ('open', 'resolved')
             AND (status = 'resolved') = (resolved_at IS NOT NULL)
             AND kind IN ('not_redundant', 'feed_near_capacity', 'supply_failed',
                          'unexpected_draw', 'path_incomplete')
             """
           )

    # Rolling back drops power workflows first, or the narrower constraint
    # would refuse them.
    execute(
      fn ->
        repo().query!(
          workflow_domains(
            ~w(component hardware_match placement topology address collector power)
          )
        )
      end,
      fn ->
        repo().query!("DELETE FROM finding_workflows WHERE domain = 'power'")

        repo().query!(
          workflow_domains(~w(component hardware_match placement topology address collector))
        )
      end
    )
  end

  defp workflow_domains(domains) do
    """
    ALTER TABLE finding_workflows
      DROP CONSTRAINT finding_workflows_valid_domain,
      ADD CONSTRAINT finding_workflows_valid_domain
        CHECK (domain IN (#{Enum.map_join(domains, ", ", &"'#{&1}'")}))
    """
  end
end
