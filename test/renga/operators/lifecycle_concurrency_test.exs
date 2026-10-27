defmodule Renga.Operators.LifecycleConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.Organization
  alias Renga.DeploymentAudit
  alias Renga.DeploymentAudit.Event
  alias Renga.Operators.OrganizationLifecycle, as: Lifecycle
  alias Renga.Repo

  test "cancellation and purge serialize: either winner prevents the other transition" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    parent = self()

    try do
      for winner <- [:cancel, :purge] do
        {:ok, organization} =
          Renga.Accounts.create_organization(%{
            name: "race",
            slug: "lifecycle-race-#{System.unique_integer([:positive])}"
          })

        context = DeploymentAudit.operator("lifecycle-race")
        {:ok, pending} = Lifecycle.change(organization.id, "schedule_deletion", context)

        try do
          first =
            request(fn ->
              Repo.transaction(fn ->
                Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
                  Ecto.UUID.dump!(pending.id)
                ])

                send(parent, {:locked, self()})

                receive do
                  :go -> operate(winner, pending, context)
                after
                  5000 -> raise "lock barrier timed out"
                end
              end)
            end)

          assert_receive {:locked, pid}, 5000

          second =
            request(fn ->
              operate(if(winner == :cancel, do: :purge, else: :cancel), pending, context)
            end)

          send(pid, :go)
          assert {:ok, {:ok, _}} = Task.await(first, 5000)
          loser = Task.await(second, 5000)

          if winner == :cancel do
            assert loser == {:error, :not_due}
            assert Repo.get!(Organization, pending.id).status == "active"
          else
            assert loser == {:error, :not_found}
            assert Repo.get(Organization, pending.id) == nil
          end
        after
          Repo.delete_all(from o in Organization, where: o.id == ^pending.id)

          Repo.delete_all(
            from e in Event, where: e.organization_id == ^pending.id or e.target_id == ^pending.id
          )
        end
      end
    after
      Sandbox.checkin(Repo)
    end
  end

  defp operate(:cancel, pending, context),
    do: Lifecycle.change(pending.id, "cancel_deletion", context)

  defp operate(:purge, pending, _context),
    do: Lifecycle.purge_due(pending.id, pending.deletion_due_at)

  defp request(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
