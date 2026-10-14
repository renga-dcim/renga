defmodule Renga.JobsFixtures do
  @moduledoc """
  Test helpers for jobs: an organization with an owner, and agents that
  advertise job capabilities.
  """

  alias Renga.Accounts
  alias Renga.Inventory

  @doc "An organization, its owner's scope, and an organization-only scope."
  def job_organization_fixture do
    organization = Renga.InventoryFixtures.organization_fixture()

    %{
      organization: organization,
      scope: member_scope(organization, "owner"),
      system_scope: Accounts.scope_for(organization)
    }
  end

  @doc "A scope for a new user holding `role` in `organization`."
  def member_scope(organization, role) do
    user = Renga.AccountsFixtures.user_fixture()
    Renga.InventoryFixtures.organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  @doc "A checked-in agent advertising `capabilities`."
  def agent_fixture(organization, capabilities \\ ["host.inventory", "inventory.collect@1"]) do
    scope = Accounts.scope_for(organization)

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "host_agent",
        name: "agent-#{System.unique_integer([:positive])}"
      })

    {:ok, {agent, _lease}} =
      Inventory.record_agent_check_in(scope, source.id, %{
        installation_id: Ecto.UUID.generate(),
        capabilities: capabilities
      })

    agent
  end
end
