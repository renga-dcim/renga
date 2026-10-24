defmodule Renga.Transfers.ImportLockingTest do
  # Outside the SQL sandbox, so writers on other connections can try the
  # target organization while the import's transaction is open.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Inventory
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Teams.Team
  alias Renga.Transfers.Export
  alias Renga.Transfers.Import

  @moduletag :tmp_dir

  # Unlinked, so a failed assertion reports itself rather than the writers
  # it leaves behind.
  setup do
    start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    :ok
  end

  # Rows an empty target may already hold, which the import locks itself.
  @allowed_before ~w(change_events organization_memberships role_assignments
                     organization_security_settings)

  # Tables with an organization_id that need not reach the organization's
  # row through a foreign key, and why.
  @unreached %{
    "deployment_audit_events" => "the operator's audit log, never the organization's data",
    "identity_providers" =>
      "a deployment provider has no organization; an organization's names it",
    # catalog_type_revisions_one_owner requires exactly one of the two
    # type references, and each reaches the organization.
    "catalog_type_revisions" => "one of hardware_type_id or module_type_id is always set",
    "component_templates" => "belongs to a catalog_type_revisions row"
  }

  test "every insert into an organization's data checks a key on its row" do
    :ok = Sandbox.checkout(Repo)

    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE fks AS (
          SELECT child.relname AS child, parent.relname AS parent,
                 bool_and(attribute.attnotnull) AS required
          FROM pg_constraint AS fk
          JOIN pg_class AS child ON child.oid = fk.conrelid
          JOIN pg_class AS parent ON parent.oid = fk.confrelid
          JOIN LATERAL unnest(fk.conkey) AS key(attnum) ON true
          JOIN pg_attribute AS attribute
            ON attribute.attrelid = child.oid AND attribute.attnum = key.attnum
          WHERE fk.contype = 'f' AND child.relnamespace = 'public'::regnamespace
            AND EXISTS (
              SELECT 1 FROM pg_attribute AS org
              WHERE org.attrelid = child.oid AND org.attname = 'organization_id'
                AND org.attnum = ANY (fk.conkey))
          GROUP BY fk.oid, child.relname, parent.relname
        ), reached(name) AS (
          SELECT 'organizations'::name
          UNION
          SELECT fks.child FROM fks JOIN reached ON fks.parent = reached.name
          WHERE fks.required
            AND (fks.parent = 'organizations' OR NOT fks.parent = ANY ($1::name[]))
        )
        SELECT table_name FROM information_schema.columns
        JOIN information_schema.tables USING (table_schema, table_name)
        WHERE column_name = 'organization_id' AND table_schema = 'public'
          AND table_type = 'BASE TABLE'
          AND table_name::name NOT IN (SELECT name FROM reached)
        ORDER BY table_name
        """,
        [@allowed_before]
      )

    assert List.flatten(rows) == @unreached |> Map.keys() |> Enum.sort()
  end

  test "writes to the target wait for the import, then land on it", %{tmp_dir: tmp} do
    with_organizations(tmp, fn path, target, owner ->
      scope = Accounts.scope_for(target)

      {:ok, imported} =
        import_paused(path, target, owner, tmp, fn ->
          writers = [
            # Through authorization, which locks the organization's row.
            resource: fn ->
              Inventory.create_resource(scope, %{kind: "server", name: "during-import"})
            end,
            # Past every context, so only the foreign key stands in the way.
            team: fn -> Repo.insert!(%Team{organization_id: target.id, name: "Late"}) end,
            # A row the empty organization already held.
            membership: fn ->
              OrganizationMembership
              |> where([m], m.organization_id == ^target.id and m.user_id == ^owner.id)
              |> Repo.update_all(set: [role: "admin"])
            end
          ]

          tasks = Enum.map(writers, fn {_name, fun} -> write(fun) end)

          finished =
            for {{name, _fun}, {_task, result}} <-
                  Enum.zip(writers, Task.yield_many(tasks, 300)),
                result != nil,
                do: name

          assert finished == []
          tasks
        end)

      assert [{:ok, _resource}, %Team{}, {1, nil}] = Enum.map(imported.writers, &Task.await/1)

      names =
        Repo.all(
          from r in Inventory.Resource, where: r.organization_id == ^target.id, select: r.name
        )

      assert "before-export" in names and "during-import" in names
    end)
  end

  test "a write that holds the target first makes the import find it not empty", %{
    tmp_dir: tmp
  } do
    with_organizations(tmp, fn path, target, owner ->
      parent = self()

      writer =
        write(fn ->
          Repo.transaction(fn ->
            {:ok, resource} =
              Inventory.create_resource(Accounts.scope_for(target), %{
                kind: "server",
                name: "first"
              })

            send(parent, :written)
            receive do: (:commit -> resource)
          end)
        end)

      assert_receive :written, 5_000
      importer = write(fn -> run(path, target, owner, tmp, []) end)

      try do
        assert Task.yield(importer, 300) == nil
      after
        send(writer.pid, :commit)
      end

      assert {:ok, _resource} = Task.await(writer)
      assert {:error, :not_empty} = Task.await(importer)
    end)
  end

  test "the revisions an import takes keep only its own organization waiting", %{
    tmp_dir: tmp
  } do
    with_organizations(tmp, fn _path, target, _owner ->
      other = organization("other")
      parent = self()

      # As the import does, under the target's revision lock.
      holder =
        write(fn ->
          Repo.transaction(fn ->
            ResourceStore.allocate_revisions!(target.id, 10_000)
            send(parent, :allocated)
            receive do: (:done -> :ok)
          end)
        end)

      try do
        assert_receive :allocated, 10_000
        create = &Inventory.create_resource(Accounts.scope_for(&1), %{kind: "server", name: "x"})
        elsewhere = write(fn -> create.(other) end)
        here = write(fn -> create.(target) end)

        assert {:ok, {:ok, _resource}} = Task.yield(elsewhere, 5_000)
        assert Task.yield(here, 300) == nil

        send(holder.pid, :done)
        assert {:ok, :ok} = Task.await(holder)
        assert {:ok, _resource} = Task.await(here)
      after
        send(holder.pid, :done)
        Repo.delete!(other)
      end
    end)
  end

  # Runs the import, and once it holds the target calls `during`, whose
  # result comes back as `writers` on the import.
  defp import_paused(path, target, owner, tmp, during) do
    parent = self()

    authorize = fn ->
      send(parent, {:locked, self()})
      receive do: (:go -> :ok)
    end

    importer = write(fn -> run(path, target, owner, tmp, authorize: authorize) end)
    assert_receive {:locked, pid}, 10_000
    # Released however `during` ends, so a failed test leaves nothing open.
    writers =
      try do
        during.()
      after
        send(pid, :go)
      end

    with {:ok, import} <- Task.await(importer, 30_000),
         do: {:ok, Map.put(import, :writers, writers)}
  end

  defp run(path, target, owner, tmp, opts) do
    Import.run(
      Repo.get!(Organization, target.id),
      path,
      [imported_by_user_id: owner.id, tmp_dir: Path.join(tmp, "import")] ++ opts
    )
  end

  defp write(fun), do: Task.Supervisor.async_nolink(__MODULE__.Tasks, fn -> checked_out(fun) end)

  defp checked_out(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  # An exported source with one resource, and an empty target whose only
  # member is the owner importing.
  defp with_organizations(tmp, fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    source = organization("source")
    target = organization("target")
    owner = user_fixture()

    try do
      {:ok, _resource} =
        Inventory.create_resource(Accounts.scope_for(source), %{
          kind: "server",
          name: "before-export"
        })

      {:ok, _membership} =
        Accounts.create_organization_membership(target, %{user_id: owner.id, role: "owner"})

      path = Path.join(tmp, "source.tar.zst")
      {:ok, _summary} = Export.write(source, path)
      Repo.delete!(source)

      fun.(path, target, owner)
    after
      Repo.delete_all(from o in Organization, where: o.id in ^[source.id, target.id])
      Repo.delete!(owner)
      Sandbox.checkin(Repo)
    end
  end

  defp organization(name) do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Import locking #{name}",
        slug: "import-locking-#{name}-#{System.unique_integer([:positive])}"
      })

    organization
  end
end
