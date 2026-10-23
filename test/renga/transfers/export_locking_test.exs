defmodule Renga.Transfers.ExportLockingTest do
  # Outside the SQL sandbox, so two connections can wait on each other.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Repo
  alias Renga.Transfers
  alias Renga.Transfers.OrganizationExport

  test "a sweep waits for a member's action on the organization instead of deadlocking" do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Export Locking",
        slug: "export-locking-#{System.unique_integer([:positive])}"
      })

    # Cleans up even if a deadlock kills the test process.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end)

    try do
      past = DateTime.add(Renga.Time.utc_now_ms(), -1, :day)

      export =
        Repo.insert!(%OrganizationExport{
          organization_id: organization.id,
          parts: [],
          status: "ready",
          bytes: 0,
          expires_at: past,
          finished_at: past
        })

      # A member's action locks the organization first, as
      # Authorization.authorize!/3 does, then the export, as a revocation
      # does; the sweep starts in between.
      parent = self()

      member =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              Repo.query!("SELECT 1 FROM organizations WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(organization.id)
              ])

              send(parent, :organization_locked)
              await_waiting_lock()

              OrganizationExport
              |> where(id: ^export.id)
              |> lock("FOR UPDATE")
              |> Repo.one!()
              |> Ecto.Changeset.change(status: "revoked", revoked_at: Renga.Time.utc_now_ms())
              |> Repo.update!()
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :organization_locked, 5_000

      sweeper =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Transfers.sweep()
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert {:ok, %OrganizationExport{status: "revoked"}} = Task.await(member, 10_000)
      assert Task.await(sweeper, 10_000) == 0
      assert Repo.get!(OrganizationExport, export.id).status == "revoked"
    after
      Sandbox.checkin(Repo)
    end
  end

  # Waits until another connection is blocked on a lock this one holds.
  defp await_waiting_lock(attempts \\ 100) do
    %{rows: [[waiting]]} = Repo.query!("SELECT count(*) FROM pg_locks WHERE NOT granted")

    cond do
      waiting > 0 ->
        :ok

      attempts == 0 ->
        flunk("the sweep never waited on a lock")

      true ->
        Process.sleep(50)
        await_waiting_lock(attempts - 1)
    end
  end
end
