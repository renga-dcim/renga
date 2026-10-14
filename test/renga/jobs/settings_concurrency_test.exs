defmodule Renga.Jobs.SettingsConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Jobs
  alias Renga.Repo

  test "concurrent updates serialize before authorization and preserve omitted settings" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    first_user = user_fixture()
    second_user = user_fixture()

    first_membership =
      organization_membership_fixture(first_user, organization, %{role: "owner"})

    second_membership =
      organization_membership_fixture(second_user, organization, %{role: "owner"})

    first_scope = Accounts.scope_for_user(first_user, organization.id)
    second_scope = Accounts.scope_for_user(second_user, organization.id)
    test_process = self()

    try do
      {:ok, tasks} =
        Repo.transaction(fn ->
          Repo.query!(
            """
            SELECT id
            FROM organization_memberships
            WHERE id IN ($1::text::uuid, $2::text::uuid)
            FOR UPDATE
            """,
            [first_membership.id, second_membership.id]
          )

          tasks = [
            settings_task(test_process, :retention, first_scope, %{retention_days: 30}),
            settings_task(test_process, :allowlist, second_scope, %{allowed_capabilities: []})
          ]

          backend_pids =
            for _ <- tasks do
              assert_receive {:settings_backend, name, backend_pid}, 5_000
              {name, backend_pid}
            end

          for {name, backend_pid} <- backend_pids do
            assert waits_for_lock?(backend_pid), "#{name} update never waited for a lock"
          end

          tasks
        end)

      for task <- tasks do
        assert {:ok, %{}} = Task.await(task, 5_000)
      end

      assert Jobs.get_settings(Repo.reload!(organization)) == %{
               allowed_capabilities: [],
               retention_days: 30
             }
    after
      Repo.delete!(organization)
      Repo.delete!(first_user)
      Repo.delete!(second_user)
      Sandbox.checkin(Repo)
    end
  end

  defp settings_task(test_process, name, scope, attrs) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(test_process, {:settings_backend, name, backend_pid})
        Jobs.update_settings(scope, attrs)
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp waits_for_lock?(backend_pid) do
    Enum.reduce_while(1..500, false, fn _, _ ->
      Repo.query!("SELECT pg_stat_clear_snapshot()")

      case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [
             backend_pid
           ]).rows do
        [["Lock"]] ->
          {:halt, true}

        _other ->
          Process.sleep(10)
          {:cont, false}
      end
    end)
  end
end
