defmodule Renga.Inventory.AtomicHostReconciliationTest do
  # Real commits are required to observe the old post-commit failure gap and
  # notification boundary. Fault triggers are scoped to this test's organization.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Reconciler
  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "host-agent"})
    {:ok, _prefix} = IPAM.create_prefix(scope, %{prefix: "192.0.2.0/24", strict: true})

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end)

    %{scope: scope, source: source}
  end

  test "manual IPAM adoption cannot erase the intervening unmanaged host transition", context do
    %{scope: scope} = context
    observation = observation(context)
    assert findings(scope) == []

    # Direct reconciliation is also a supported entry point. The caller may
    # disappear after it returns, so no Inventory post-commit wrapper follows.
    assert {:ok, resource, true} =
             Reconciler.reconcile_once(Accounts.scope_for(scope.organization), observation)

    [interface] = Inventory.list_interfaces(scope, resource.id)
    [address] = Inventory.list_addresses(scope, interface.id)

    # An independent IPAM writer immediately restores the non-finding state.
    assert {:ok, _managed} = IPAM.adopt_address(scope, address.id)
    assert [%{status: "resolved", resolved_at: %DateTime{}, details: details}] = findings(scope)
    assert details["observed_address_id"] == address.id
    assert Enum.any?(details["evidence"], &(&1["observation_id"] == observation.id))

    assert [%{status: "succeeded"}] =
             Inventory.list_observation_reconciliations(scope, observation.id)
  end

  for {stage, table, condition, actor} <- [
        {:triage, "change_events", "NEW.kind = 'rule_applied'", :human},
        {:address, "address_findings", "true", :system}
      ] do
    @table table
    @condition condition
    @actor actor

    test "#{stage} failure blocks the host commit and retains evidence for explicit retry",
         context do
      %{scope: scope} = context
      {:ok, team} = Renga.Teams.create_team(scope, %{name: "Platform"})

      {:ok, %{rule: _rule}} =
        Renga.TriageRules.create_rule(scope, %{
          kind: "ownership",
          name: "Host ownership",
          hostname_pattern: "web-*",
          team_id: team.id
        })

      observation = observation(context)
      actor = if @actor == :human, do: scope, else: Accounts.scope_for(scope.organization)
      :ok = Changes.subscribe(scope)
      install_failure!(scope.organization_id, @table, @condition)

      try do
        # Triage used to be best-effort after canonical commit. Both a failure
        # there and a later address failure must now undo the host and its rule.
        assert {:error, %{status: "failed", attempt: 1}} =
                 Inventory.reconcile_observation_once(actor, observation.id)

        assert Enum.reject(Inventory.list_resources(scope), &(&1.kind == "prefix")) == []
        assert [accepted] = Inventory.list_observations(scope)
        assert accepted.id == observation.id
        assert accepted.payload == observation.payload
        assert findings(scope) == []

        refute Repo.exists?(
                 from event in ChangeEvent,
                   where:
                     event.organization_id == ^scope.organization_id and
                       event.kind == "rule_applied"
               )

        refute_receive {:inventory_changed, _}, 50

        # Replaying accepted evidence is not an implicit retry of a terminal failure.
        assert {:error, %{status: "failed", attempt: 1}} =
                 Inventory.reconcile_observation_once(actor, observation.id)
      after
        remove_failure!(@table)
      end

      assert {:ok, resource, true} = Inventory.reconcile_observation(actor, observation.id)
      assert Inventory.get_resource!(scope, resource.id).owner_team_id == team.id
      assert [%{status: "open"}] = findings(scope)

      assert [%{status: "failed", attempt: 1}, %{status: "succeeded", attempt: 2}] =
               Inventory.list_observation_reconciliations(scope, observation.id)

      # Nested triage and projections cannot announce uncommitted state.
      assert_receive {:inventory_changed, organization_id}, 1_000
      assert organization_id == scope.organization_id
      refute_receive {:inventory_changed, _}, 50
    end
  end

  for {before_kind, after_kind} <- [{"host_agent", "manual"}, {"manual", "host_agent"}],
      entry <- [:retry, :once, :replay],
      actor <- [:human, :system] do
    @before_kind before_kind
    @after_kind after_kind
    @entry entry
    @actor actor

    test "#{actor} #{entry} retains effect ownership across #{@before_kind} to #{@after_kind}",
         %{scope: scope, source: source} = context do
      {:ok, source} = Inventory.update_source(scope, source, %{kind: @before_kind})
      observation = observation(context)
      actor = if @actor == :human, do: scope, else: Accounts.scope_for(scope.organization)
      action = if @entry == :retry, do: :reconcile_observation, else: :reconcile_observation_once

      if @entry == :replay,
        do: assert({:ok, _, true} = Inventory.reconcile_observation_once(actor, observation.id))

      parent = self()
      token = make_ref()

      worker =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            receive do
              :start -> apply(Inventory, action, [actor, observation.id])
            end
          after
            Sandbox.checkin(Repo)
          end
        end)

      handler = {__MODULE__, token}

      :ok =
        :telemetry.attach(handler, [:renga, :repo, :query], &__MODULE__.turn_barrier/4, %{
          worker: worker.pid,
          parent: parent,
          token: token
        })

      send(worker.pid, :start)

      updater =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            receive do
              :start -> :ok
            end

            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:updating_source, backend})
            Inventory.update_source(scope, source, %{kind: @after_kind})
          after
            Sandbox.checkin(Repo)
          end
        end)

      try do
        assert_receive {:source_read, ^token}, 5_000
        send(updater.pid, :start)
        assert_receive {:updating_source, backend}, 5_000
        assert_source_update_waits!(backend)
        assert Inventory.get_source!(scope, source.id).kind == @before_kind
        send(worker.pid, {:resume_source, token})

        # The commit barrier runs after PostgreSQL released the source lock,
        # but before Inventory's outward callback can choose any follow-up.
        assert_receive {:canonical_committed, ^token}, 5_000
        assert {:ok, %{kind: @after_kind}} = Task.await(updater, 5_000)

        if @before_kind == "host_agent" do
          [resource] = Enum.reject(Inventory.list_resources(scope), &(&1.kind == "prefix"))
          [interface] = Inventory.list_interfaces(scope, resource.id)
          [address] = Inventory.list_addresses(scope, interface.id)
          assert {:ok, _} = IPAM.adopt_address(scope, address.id)
        end

        send(worker.pid, {:resume_commit, token})
        assert {:ok, _, _} = Task.await(worker, 5_000)
        assert Inventory.get_source!(scope, source.id).kind == @after_kind
        expected = if @before_kind == "host_agent", do: "resolved", else: "open"
        assert [%{status: ^expected}] = findings(scope)

        assert [%{status: "succeeded", attempt: 1}] =
                 Inventory.list_observation_reconciliations(scope, observation.id)
      after
        :telemetry.detach(handler)
        send(worker.pid, {:resume_source, token})
        send(worker.pid, {:resume_commit, token})
        send(updater.pid, :start)
        if Process.alive?(worker.pid), do: Task.shutdown(worker, :brutal_kill)
        if Process.alive?(updater.pid), do: Task.shutdown(updater, :brutal_kill)
      end
    end
  end

  for actor <- [:human, :system] do
    @actor actor

    test "#{actor} faulted successful replay cannot leak host effects after rollback", context do
      %{scope: scope} = context
      actor = if @actor == :human, do: scope, else: Accounts.scope_for(scope.organization)
      observation = observation(context)
      assert {:ok, resource, true} = Inventory.reconcile_observation_once(actor, observation.id)
      [finding] = findings(scope)

      # Seed a stale projection so replay must refresh it rather than take the
      # finding writer's unchanged-row fast path.
      finding = finding |> Ecto.Changeset.change(message: "stale projection") |> Repo.update!()

      # Sequences survive rollback. The first update faults inside the canonical
      # turn; a leaked best-effort refresh would succeed and alter the finding.
      Repo.query!("CREATE SEQUENCE atomic_host_replay_calls")

      Repo.query!("""
      CREATE FUNCTION atomic_host_replay_failure() RETURNS trigger AS $$
      BEGIN
        IF NEW.organization_id = '#{scope.organization_id}'::uuid THEN
          IF nextval('atomic_host_replay_calls') = 1 THEN
            RAISE EXCEPTION 'injected terminal replay failure';
          END IF;
          NEW.message = 'leaked post-commit host effect';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER atomic_host_replay_failure BEFORE UPDATE ON address_findings
      FOR EACH ROW EXECUTE FUNCTION atomic_host_replay_failure()
      """)

      try do
        assert {:ok, replayed, false} =
                 Inventory.reconcile_observation_once(actor, observation.id)

        assert replayed.id == resource.id

        assert [[1, true]] =
                 Repo.query!("SELECT last_value, is_called FROM atomic_host_replay_calls").rows

        assert [^finding] = findings(scope)

        assert [%{status: "succeeded", attempt: 1}] =
                 Inventory.list_observation_reconciliations(scope, observation.id)
      after
        Repo.query!("DROP TRIGGER atomic_host_replay_failure ON address_findings")
        Repo.query!("DROP FUNCTION atomic_host_replay_failure()")
        Repo.query!("DROP SEQUENCE atomic_host_replay_calls")
      end
    end
  end

  test "post-commit callback failures cannot append a failed canonical attempt", context do
    observation = observation(context)

    for entry <- [&Reconciler.reconcile/3, &Reconciler.reconcile_once/3] do
      assert_raise RuntimeError, "outward callback failed", fn ->
        entry.(context.scope, observation,
          after_commit: fn _result, _owner -> raise "outward callback failed" end
        )
      end

      assert [%{status: "succeeded", attempt: 1}] =
               Inventory.list_observation_reconciliations(context.scope, observation.id)
    end
  end

  test "Inventory dispatch cannot mistake a nested transaction for a commit", context do
    observation = observation(context)

    for entry <- [&Inventory.reconcile_observation/2, &Inventory.reconcile_observation_once/2] do
      assert_raise ArgumentError, "post-commit dispatch requires top-level reconciliation", fn ->
        Repo.transaction(fn -> entry.(context.scope, observation.id) end)
      end
    end

    assert Inventory.list_observation_reconciliations(context.scope, observation.id) == []
  end

  # Synchronous query telemetry pauses the real caller at the two boundaries,
  # with no production hooks or timing guesses. The updater uses a second
  # connection; pg_stat_activity below proves an actual database lock wait.
  def turn_barrier(_event, _measurements, metadata, %{worker: worker} = config) do
    if self() == worker and is_binary(metadata.query) do
      key = {__MODULE__, config.token}
      state = Process.get(key, :unread)

      cond do
        state == :unread and String.contains?(metadata.query, "FROM \"sources\"") ->
          Process.put(key, :source_read)
          send(config.parent, {:source_read, config.token})

          receive do
            {:resume_source, token} when token == config.token -> :ok
          end

        state == :source_read and metadata.query == "commit" ->
          Process.put(key, :committed)
          send(config.parent, {:canonical_committed, config.token})

          receive do
            {:resume_commit, token} when token == config.token -> :ok
          end

        true ->
          :ok
      end
    end
  end

  defp assert_source_update_waits!(backend, remaining \\ 250) do
    [[waiting]] =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock')",
        [backend]
      ).rows

    cond do
      waiting ->
        :ok

      remaining == 0 ->
        flunk("source kind update never waited for the canonical turn")

      true ->
        Process.sleep(10)
        assert_source_update_waits!(backend, remaining - 1)
    end
  end

  defp observation(%{scope: scope, source: source}) do
    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "host-transition",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "host-transition", "hostname" => "web-01"},
              "attributes" => %{"hostname" => "web-01"},
              "interfaces" => [%{"name" => "eth0", "addresses" => ["192.0.2.5/24"]}]
            }
          ]
        }
      })

    observation
  end

  defp findings(scope) do
    Repo.all(
      from finding in AddressFinding,
        where:
          finding.organization_id == ^scope.organization_id and
            finding.kind == "unmanaged_in_strict_prefix",
        order_by: finding.inserted_at
    )
  end

  defp install_failure!(organization_id, table, condition) do
    Repo.query!("""
    CREATE FUNCTION atomic_host_effect_failure() RETURNS trigger AS $$
    BEGIN
      IF NEW.organization_id = '#{organization_id}'::uuid AND (#{condition}) THEN
        RAISE EXCEPTION 'injected atomic host effect failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER atomic_host_effect_failure
    BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION atomic_host_effect_failure()
    """)
  end

  defp remove_failure!(table) do
    Repo.query!("DROP TRIGGER atomic_host_effect_failure ON #{table}")
    Repo.query!("DROP FUNCTION atomic_host_effect_failure()")
  end
end
