defmodule Renga.Repo.Migrations.AddAddressFindingWorkflows do
  @moduledoc """
  RFD 4, Phase 5: address findings join the Inbox with the shared workflow,
  and a member who cannot adopt an observed address may request adoption.
  """
  use Ecto.Migration

  def up do
    drop constraint(:finding_workflows, :finding_workflows_valid_domain)

    create constraint(:finding_workflows, :finding_workflows_valid_domain,
             check:
               "domain IN ('component', 'hardware_match', 'placement', 'topology', 'address')"
           )

    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override', 'owner', 'expectation', 'adoption')"
           )
  end

  def down do
    execute "DELETE FROM change_requests WHERE kind = 'adoption'"
    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override', 'owner', 'expectation')"
           )

    execute "DELETE FROM finding_workflows WHERE domain = 'address'"
    drop constraint(:finding_workflows, :finding_workflows_valid_domain)

    create constraint(:finding_workflows, :finding_workflows_valid_domain,
             check: "domain IN ('component', 'hardware_match', 'placement', 'topology')"
           )
  end
end
