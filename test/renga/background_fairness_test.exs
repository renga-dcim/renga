defmodule Renga.BackgroundFairnessTest do
  # Cancellation must drop only the executing batch's connection, not the
  # borrowed Sandbox transaction containing every organization's fixtures.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2, agent_fixture: 1]
  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.{Organization, User}
  alias Renga.{Assignments, Background, Inventory, Jobs, Repo}
  alias Renga.Roles.Assignment

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(:restore_mode, fn -> Sandbox.mode(Repo, :manual) end)

    workers = ["assignment_expiry", "job_sweep"]

    cursors =
      Repo.query!(
        "SELECT worker, last_organization_id FROM background_cursors WHERE worker = ANY($1)",
        [workers]
      ).rows

    {:ok, scopes} =
      Repo.transaction(fn ->
        for _ <- 1..2, do: member_scope(organization_fixture(), "viewer")
      end)

    ids = Enum.map(scopes, & &1.organization_id)
    users = Enum.map(scopes, & &1.user.id)
    worker = "expiry-cancellation-#{Ecto.UUID.generate()}"

    on_exit(fn ->
      :ok = Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from org in Organization, where: org.id in ^ids)
      Repo.delete_all(from user in User, where: user.id in ^users)
      Repo.query!("DELETE FROM background_cursors WHERE worker = ANY($1)", [[worker | workers]])

      for [name, previous] <- cursors do
        Repo.query!(
          "INSERT INTO background_cursors(worker, last_organization_id) VALUES ($1, $2)",
          [name, previous]
        )
      end

      Sandbox.checkin(Repo)
    end)

    %{scopes: scopes, worker: worker}
  end

  test "expiry makes bounded progress for a large organization without delaying a quiet one",
       %{scopes: [noisy_scope, quiet_scope]} do
    deadline = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    noisy =
      for _ <- 1..26 do
        Repo.insert!(%Assignment{
          organization_id: noisy_scope.organization_id,
          membership_id: noisy_scope.membership_id,
          built_in_role: "member",
          valid_until: deadline
        })
      end

    quiet =
      Repo.insert!(%Assignment{
        organization_id: quiet_scope.organization_id,
        membership_id: quiet_scope.membership_id,
        built_in_role: "member",
        valid_until: deadline
      })

    # Do not let Task's caller chain borrow a fixture connection. Each child
    # checks out its own connection and each expired row really commits.
    Sandbox.checkin(Repo)
    Assignments.sweep_expired()
    assert Repo.reload!(quiet).expired_at
    completed = Enum.count(noisy, &Repo.reload!(&1).expired_at)
    assert completed in 1..25

    Sandbox.checkin(Repo)
    Assignments.sweep_expired()
    assert Enum.all?(noisy, &Repo.reload!(&1).expired_at)
    assert expiry_events(noisy_scope, quiet.id) == []
    assert length(expiry_events(quiet_scope, quiet.id)) == 1
  end

  test "one organization's expired job backlog cannot fill another's batch", %{scopes: scopes} do
    [noisy_org, quiet_org] = Enum.map(scopes, &Repo.get!(Organization, &1.organization_id))
    noisy_agent = agent_fixture(noisy_org)
    quiet_agent = agent_fixture(quiet_org)

    noisy =
      for _ <- 1..27 do
        {:ok, job} =
          Jobs.create_system_job(noisy_org.id, noisy_agent.id, "inventory.collect@1", %{})

        job
      end

    {:ok, quiet} =
      Jobs.create_system_job(quiet_org.id, quiet_agent.id, "inventory.collect@1", %{})

    now = DateTime.add(Renga.Time.utc_now_ms(), 2 * 86_400)
    Sandbox.checkin(Repo)
    Jobs.sweep(now)
    assert Repo.reload!(quiet).state == "expired"
    assert Enum.count(noisy, &(Repo.reload!(&1).state == "expired")) == 25

    Sandbox.checkin(Repo)
    Jobs.sweep(now)
    assert Enum.all?(noisy, &(Repo.reload!(&1).state == "expired"))
  end

  test "batch cancellation preserves prior commits and the quiet organization's connection",
       %{scopes: scopes, worker: worker} do
    [noisy, quiet] = scopes |> Enum.map(& &1.organization_id) |> Enum.sort()

    ready =
      from org in Organization,
        where: org.id in ^[noisy, quiet],
        select: %{organization_id: org.id}

    parent = self()
    Sandbox.checkin(Repo)

    results =
      Background.run(
        worker,
        ready,
        fn
          ^noisy ->
            Repo.transaction(fn ->
              Repo.update_all(from(org in Organization, where: org.id == ^noisy),
                set: [name: "committed"]
              )
            end)

            Repo.transaction(fn ->
              Repo.update_all(from(org in Organization, where: org.id == ^noisy),
                set: [name: "rolled back"]
              )

              send(parent, {:transaction_started, self()})
              Repo.query!("SELECT pg_sleep(2)")
            end)

          ^quiet ->
            Repo.update_all(from(org in Organization, where: org.id == ^quiet),
              set: [name: "healthy"]
            )

            :healthy
        end,
        budget_ms: 1_000,
        batch_timeout_ms: 250
      )

    assert_receive {:transaction_started, batch}
    monitor = Process.monitor(batch)
    assert_receive {:DOWN, ^monitor, :process, ^batch, _reason}, 100
    assert [nil, {:ok, :healthy}] = results
    assert Repo.get!(Organization, noisy).name == "committed"
    assert Repo.get!(Organization, quiet).name == "healthy"
  end

  defp expiry_events(scope, assignment_id) do
    scope
    |> Inventory.list_activity()
    |> Enum.filter(&(&1.kind == "role_expired" and &1.metadata["assignment_id"] == assignment_id))
  end
end
