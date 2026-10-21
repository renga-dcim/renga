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

  @doc "A server resource that `agent` reports on, through a claim from its source."
  def reported_resource_fixture(organization, agent, name \\ "compute-01") do
    scope = Accounts.scope_for(organization)
    suffix = System.unique_integer([:positive])

    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    {:ok, observation} =
      Inventory.create_observation(scope, agent.source_id, %{
        observation_id: "report-#{suffix}",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"hostname" => name}
      })

    {:ok, _claim} =
      Inventory.create_resource_identifier_claim(scope, agent.source_id, observation.id, %{
        resource_id: resource.id,
        kind: "hostname",
        value: name,
        confidence: 100
      })

    resource
  end

  @doc """
  Gives `agent` an approved Ed25519 installation key (RFD 13). Returns the
  key row and its private key.
  """
  def approved_key_fixture(organization, agent) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      Renga.Repo.transaction(fn ->
        Renga.Inventory.InstallationKeys.present!(
          agent,
          %{algorithm: "ed25519", public_key: public_key},
          Renga.Time.utc_now_ms()
        )
      end)

    {:ok, key} =
      Renga.Inventory.InstallationKeys.approve(
        member_scope(organization, "owner"),
        key.id,
        key.fingerprint
      )

    {key, private_key}
  end

  @doc """
  Binds a resource `agent` reports to `agent` and its approved key, so
  privileged jobs may run there. Returns the resource, the binding, and the
  private key that signs leases.
  """
  def target_binding_fixture(organization, agent) do
    resource =
      reported_resource_fixture(
        organization,
        agent,
        "bound-#{System.unique_integer([:positive])}"
      )

    {key, private_key} = approved_key_fixture(organization, agent)

    {:ok, binding} =
      Renga.Jobs.TargetBindings.bind(
        member_scope(organization, "owner"),
        resource.id,
        agent.id,
        key.fingerprint
      )

    %{resource: resource, binding: binding, key: key, private_key: private_key}
  end

  @doc "Signs a lease offer as the agent would."
  def sign_offer(offer, agent, private_key) do
    message =
      Renga.Jobs.SignedLeases.message(
        offer.job.id,
        offer.lease_token,
        offer.nonce,
        agent.installation_id,
        offer.job.resource_id,
        offer.job.target_binding_version
      )

    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  @doc """
  Leases privileged jobs the way an agent does: takes the offers and claims
  each with a signature. Returns `{:ok, [{job, token}]}`.
  """
  def lease_privileged(scope, agent, keys, private_key, limit \\ 1) do
    {:ok, offers} = Renga.Jobs.SignedLeases.offer(scope, agent, keys, limit)

    leased =
      for offer <- offers do
        {:ok, {job, token}} =
          Renga.Jobs.SignedLeases.claim(
            scope,
            agent,
            offer.job.id,
            offer.lease_token,
            offer.nonce,
            sign_offer(offer, agent, private_key)
          )

        {job, token}
      end

    {:ok, leased}
  end
end
