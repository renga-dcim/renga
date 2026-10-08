defmodule Renga.TriageRulesConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Repo
  alias Renga.Teams
  alias Renga.TriageRules

  test "rule authorization waits for the organization without holding the membership" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    test_process = self()

    try do
      {:ok, rule_task} =
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM organizations WHERE id = $1::text::uuid FOR UPDATE", [
            organization.id
          ])

          task =
            Task.async(fn ->
              :ok = Sandbox.checkout(Repo, sandbox: false)

              try do
                %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                send(test_process, {:rule_backend, backend_pid})
                TriageRules.create_rule(scope, %{kind: "top_of_rack", name: "ToR"})
              after
                Sandbox.checkin(Repo)
              end
            end)

          assert_receive {:rule_backend, backend_pid}, 5_000

          waiting? =
            Enum.reduce_while(1..500, false, fn _, _ ->
              Repo.query!("SELECT pg_stat_clear_snapshot()")

              case Repo.query!(
                     "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
                     [backend_pid]
                   ).rows do
                [["Lock"]] ->
                  {:halt, true}

                _ ->
                  Process.sleep(10)
                  {:cont, false}
              end
            end)

          assert waiting?, "rule mutation never waited for the organization lock"

          # NOWAIT fails if rule authorization has already locked membership.
          Repo.query!(
            "SELECT id FROM organization_memberships WHERE id = $1::text::uuid FOR UPDATE NOWAIT",
            [scope.membership_id]
          )

          assert {:ok, _team} = Teams.create_team(scope, %{name: "Platform"})
          task
        end)

      assert {:ok, %{rule: %{name: "ToR"}}} = Task.await(rule_task, 5_000)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
