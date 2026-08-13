defmodule Renga.Inventory.IntakeRegistrationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.Repo

  @timeout 5_000

  test "concurrent first check-in and observation converge on one Source and Agent" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = Ecto.UUID.generate()

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent intake #{suffix}",
        slug: "concurrent-intake-#{suffix}"
      })

    user =
      Repo.insert!(%User{
        email: "concurrent-intake-#{suffix}@example.com",
        confirmed_at: Renga.Time.utc_now_ms()
      })

    membership =
      Repo.insert!(%OrganizationMembership{
        organization_id: organization.id,
        user_id: user.id,
        role: "admin",
        status: "active"
      })

    scope = Renga.Accounts.Scope.for_membership(user, organization, membership)
    {:ok, {key, _token}} = Inventory.create_intake_api_key(scope, %{name: "Concurrent"})
    installation_id = Ecto.UUID.generate()
    parent = self()

    check_in =
      concurrent_request(parent, fn ->
        Inventory.record_intake_agent_check_in(scope, key, installation_id, %{
          capabilities: ["host.inventory"]
        })
      end)

    observation =
      concurrent_request(parent, fn ->
        Inventory.ingest_intake_observation(scope, key, installation_id, %{}, %{
          idempotency_key: "concurrent-first-observation",
          observed_at: Renga.Time.utc_now_ms(),
          payload: %{"hostname" => "concurrent-host"}
        })
      end)

    assert_receive {:ready, first_pid}, @timeout
    assert_receive {:ready, second_pid}, @timeout
    send(first_pid, :go)
    send(second_pid, :go)

    assert {:ok, {%Agent{}, _lease}} = Task.await(check_in, @timeout)

    assert {:ok, {%Agent{}, _lease, %Observation{}, :created}} =
             Task.await(observation, @timeout)

    assert Repo.aggregate(
             from(source in Source, where: source.organization_id == ^organization.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(agent in Agent, where: agent.organization_id == ^organization.id),
             :count
           ) == 1

    [agent] = Inventory.list_agents(scope)
    [observation] = Inventory.list_observations(scope)
    assert observation.source_id == agent.source_id
    assert agent.installation_id == installation_id

    Repo.delete!(organization)
    Sandbox.checkin(Repo)
  end

  defp concurrent_request(parent, request) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})

      try do
        receive do
          :go -> request.()
        after
          @timeout -> raise "timed out waiting to start concurrent intake request"
        end
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
