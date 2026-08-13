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

  test "different installations in one organization register concurrently" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {organization, scope, key} = intake_fixture("Parallel intake")
    blocked_installation_id = Ecto.UUID.generate()
    parallel_installation_id = Ecto.UUID.generate()

    Repo.query!("BEGIN")

    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [
      organization.id,
      blocked_installation_id
    ])

    parent = self()

    blocked_request =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:blocked_backend, backend_pid})

        try do
          Inventory.record_intake_agent_check_in(scope, key, blocked_installation_id)
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:blocked_backend, backend_pid}, @timeout
    await_backend_lock_wait!(backend_pid, System.monotonic_time(:millisecond) + @timeout)

    parallel_request =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Inventory.record_intake_agent_check_in(scope, key, parallel_installation_id)
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert {:ok, {%Agent{installation_id: ^parallel_installation_id}, _lease}} =
               Task.await(parallel_request, 1_000)
    after
      Repo.query!("COMMIT")
    end

    assert {:ok, {%Agent{installation_id: ^blocked_installation_id}, _lease}} =
             Task.await(blocked_request, @timeout)

    Repo.delete!(organization)
    Sandbox.checkin(Repo)
  end

  test "concurrent first check-in and observation converge on one Source and Agent" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {organization, scope, key} = intake_fixture("Concurrent intake")
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

  defp intake_fixture(name) do
    suffix = Ecto.UUID.generate()

    {:ok, organization} =
      Accounts.create_organization(%{name: "#{name} #{suffix}", slug: "intake-#{suffix}"})

    user =
      Repo.insert!(%User{
        email: "intake-#{suffix}@example.com",
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
    {organization, scope, key}
  end

  defp await_backend_lock_wait!(backend_pid, deadline) do
    %{rows: [[wait_event_type]]} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

    cond do
      wait_event_type == "Lock" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend #{backend_pid} did not wait for a lock")

      true ->
        Process.sleep(10)
        await_backend_lock_wait!(backend_pid, deadline)
    end
  end
end
