defmodule Renga.Repo.Migrations.AddAgentLastContactedAt do
  @moduledoc """
  Records each agent's latest authenticated API contact separately from its
  lease (RFD 1, "Collection model"): an agent whose payloads are rejected is
  still in contact even though nothing renews its lease.
  """
  use Ecto.Migration

  def up do
    alter table(:agents) do
      add :last_contacted_at, :utc_datetime_usec
    end

    # Until now every authenticated request that reached the database also
    # renewed the lease, so the last renewal is the best known contact.
    execute """
    UPDATE agents
    SET last_contacted_at = agent_leases.renewed_at
    FROM agent_leases
    WHERE agent_leases.agent_id = agents.id
      AND agent_leases.organization_id = agents.organization_id
    """
  end

  def down do
    alter table(:agents) do
      remove :last_contacted_at
    end
  end
end
