defmodule Renga.Inventory.ReconciliationWorkTest do
  # Ownership/deadline tests need actual commits and independent connections,
  # not nested sandbox transactions or an in-memory queue.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ReconciliationLane
  alias Renga.Inventory.ReconciliationWork, as: Work
  alias Renga.Inventory.Reconciler
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export

  @limits %{max_units: 1_000, max_bytes: 1_000_000}

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    fixture = installation()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      # Deployment audit intentionally outlives organizations; committed test
      # fixtures must remove their own audit rows instead of relying on cascade.
      Repo.delete_all(
        from event in Renga.DeploymentAudit.Event,
          where: event.organization_id == ^fixture.scope.organization_id
      )

      Repo.delete_all(
        from org in Accounts.Organization, where: org.id == ^fixture.scope.organization_id
      )

      Repo.delete!(fixture.scope.user)
      Sandbox.checkin(Repo)
    end)

    fixture
  end

  test "admission is validated, explicitly authorized and has no capacity defaults", context do
    params = host("validation")
    assert_raise ArgumentError, fn -> admit(context, params, %{}) end

    assert {:error, :unsupported_authority} =
             Work.admit(
               context.scope,
               nil,
               context.installation_id,
               context.agent.source_id,
               params,
               @limits
             )

    assert {:error, {:invalid_payload, _}} = admit(context, Map.delete(params, "observed_at"))
    assert Repo.aggregate(Work, :count) == 0
    assert Inventory.list_observations(context.scope) == []

    assert {:ok, %{work: work, receipt: receipt}} = admit(context, params)
    assert work.original_key_id == context.key.id
    assert work.units == 1
    assert work.bytes == byte_size(Jason.encode!(params))
    assert Work.receipt(context.scope, work.observation_id) == receipt
    assert lane(context).pending_units == 1
    assert lane(context).pending_bytes == work.bytes
  end

  test "live intake atomically reserves work, receipt lookup never renews, and a restarted worker drains it",
       context do
    params = host("live-intake")
    source = Repo.get!(Inventory.Source, context.agent.source_id)
    {:ok, attrs} = AgentPayload.validate_observation(params, source)

    assert {:ok, {agent, lease, observation, :created}} =
             Inventory.ingest_intake_observation(
               context.scope,
               context.key,
               context.installation_id,
               %{},
               attrs
             )

    assert Inventory.list_resources(context.scope) == []

    assert %{receipt: receipt, work: %{status: "pending"} = work} =
             Work.accepted(context.scope, observation)

    assert lane(context).pending_units == 1

    {:ok, claim} = claim(context, claim_ms: 30)
    await_expired!(context)
    before_lane = lane(context)

    assert {:ok, %{receipt: ^receipt}} =
             Inventory.intake_observation_receipt(
               context.scope,
               context.key,
               context.installation_id,
               params["observation_id"],
               nil
             )

    assert Repo.get!(Inventory.AgentLease, lease.id) == lease
    assert Repo.get!(Inventory.Agent, agent.id) == agent
    assert lane(context) == before_lane
    assert {:error, :expired_claim} = Work.execute_host(claim)

    # A supervised replacement needs no wakeup or acceptance-process state.
    Sandbox.checkin(Repo)
    Sandbox.mode(Repo, :auto)
    {:ok, worker} = Renga.Inventory.ReconciliationWorker.start_link(name: nil, interval: 10)

    try do
      await_succeeded!(context, work.id)
      assert [%{kind: "server"} = resource] = Inventory.list_resources(context.scope)
      assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "live-intake"
      assert lane(context).pending_units == 0
      assert lane(context).pending_bytes == 0
      assert Work.receipt(context.scope, observation.id) == receipt
    after
      GenServer.stop(worker)
      Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo, sandbox: false)
    end
  end

  for status <- ["succeeded", "failed"] do
    test "legacy #{status} evidence is read-only for machine and once entrypoints", context do
      params = host("legacy-terminal")

      {:ok, attrs} =
        AgentPayload.validate_observation(
          params,
          Repo.get!(Inventory.Source, context.agent.source_id)
        )

      {:ok, observation} =
        Inventory.create_observation(context.scope, context.agent.source_id, attrs)

      {:ok, resource} =
        Inventory.create_resource(context.scope, %{kind: "server", name: "Legacy host"})

      now = Renga.Time.utc_now_ms()

      {:ok, terminal} =
        Inventory.create_observation_reconciliation(context.scope, observation.id, %{
          status: unquote(status),
          attempt: 1,
          started_at: now,
          completed_at: now,
          matched_resource_id: if(unquote(status) == "succeeded", do: resource.id)
        })

      machine = Accounts.scope_for(context.scope.organization)
      before_events = Repo.aggregate(ChangeEvent, :count)

      for {scope, action} <- [
            {machine, :reconcile_observation},
            {machine, :reconcile_observation_once},
            {context.scope, :reconcile_observation_once}
          ] do
        result = apply(Inventory, action, [scope, observation.id])

        if unquote(status) == "succeeded" do
          assert {:ok, %Inventory.Resource{id: id}, false} = result
          assert id == resource.id
        else
          assert result == {:error, terminal}
        end
      end

      assert Work.accepted(context.scope, observation) == nil
      assert Repo.get(ReconciliationLane, context.scope.organization_id) == nil

      assert Inventory.list_observation_reconciliations(context.scope, observation.id) == [
               terminal
             ]

      assert Inventory.get_resource!(context.scope, resource.id) == resource
      assert Repo.aggregate(ChangeEvent, :count) == before_events

      assert {:ok, _, _} = Inventory.reconcile_observation(context.scope, observation.id)

      assert %{work: %{origin: "maintenance", status: "succeeded"}} =
               Work.accepted(context.scope, observation)

      assert Repo.exists?(
               from event in ChangeEvent,
                 where:
                   event.observation_id == ^observation.id and
                     event.field == "reconciliation_legacy_retry"
             )
    end
  end

  test "maintenance and rediscovery share the execution slot, released on caller death",
       context do
    assert {:ok, %{work: work}} = admit(context, host("shared-slot"))
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _permit} = Renga.IntakeCapacity.acquire(:reconciliation, 1)
        send(parent, :slot_owned)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :slot_owned
    assert {:ok, :busy} = Renga.Inventory.ReconciliationWorker.run_once(wait_ms: 0)

    caller =
      concurrent(fn ->
        Inventory.reconcile_observation_once(context.scope, work.observation_id)
      end)

    try do
      assert Task.yield(caller, 100) == nil
      assert lane(context).token == nil
      assert Inventory.list_resources(context.scope) == []
      assert Work.get(context.scope, work.id).generation == 0
      send(owner, :stop)
      assert {:ok, %Inventory.Resource{}, true} = Task.await(caller, 5_000)
      assert Work.get(context.scope, work.id).status == "succeeded"
      assert lane(context).pending_units == 0
    after
      send(owner, :stop)
      if Process.alive?(caller.pid), do: Task.shutdown(caller, :brutal_kill)
    end
  end

  test "rejected first-use intake rolls registration, leases, streams and evidence back",
       context do
    org = context.scope.organization_id

    Repo.insert!(%Renga.Limits.OrganizationLimit{
      organization_id: org,
      name: "pending_work_units",
      value: 0
    })

    installation_id = Ecto.UUID.generate()

    {:ok, attrs} =
      AgentPayload.validate_observation(host("no-room"), %Inventory.Source{kind: "host_agent"})

    assert {:error, :capacity} =
             Inventory.ingest_intake_observation(
               context.scope,
               context.key,
               installation_id,
               %{},
               attrs
             )

    refute Repo.get_by(Inventory.Agent, organization_id: org, installation_id: installation_id)
    assert Inventory.list_observations(context.scope) == []
    refute Repo.get(ReconciliationLane, org)
    assert length(Inventory.list_sources(context.scope)) == 1
  end

  test "unsupported synchronous duplicates are not fabricated durable receipts", context do
    for {name, original_key} <- [{"no-key", nil}, {"same-key", context.key.id}] do
      params = host(name)

      {:ok, attrs} =
        AgentPayload.validate_observation(
          params,
          Repo.get!(Inventory.Source, context.agent.source_id)
        )

      {:ok, observation, :created} =
        Inventory.accept_observation(
          context.scope,
          context.agent.source_id,
          Map.put(attrs, :intake_api_key_id, original_key)
        )

      assert {:error, :unsupported_existing_observation} = admit(context, params)
      assert Work.receipt(context.scope, observation.id) == nil
      assert Repo.get!(Observation, observation.id).intake_api_key_id == original_key
    end

    assert Repo.aggregate(Work, :count) == 0
  end

  test "concurrent duplicate admission creates one receipt and charge", context do
    params = host("duplicate")
    results = concurrent_admissions(context, params, params, @limits)

    assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.disposition end)) == [
             :created,
             :duplicate
           ]

    assert Enum.map(results, fn {:ok, result} -> result.receipt end) |> Enum.uniq() |> length() ==
             1

    assert lane(context).pending_units == 1
    assert lane(context).pending_bytes == byte_size(Jason.encode!(params))
    assert length(Inventory.list_observations(context.scope)) == 1
  end

  for measure <- [:units, :bytes] do
    @measure measure
    test "concurrent last-#{measure} admission rolls back rejected evidence", context do
      limits =
        if @measure == :units,
          do: %{max_units: 1, max_bytes: 1_000_000},
          else: %{max_units: 1_000, max_bytes: byte_size(Jason.encode!(host("slot-a")))}

      results = concurrent_admissions(context, host("slot-a"), host("slot-b"), limits)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :capacity} in results
      assert lane(context).pending_units == 1
      assert lane(context).pending_bytes == byte_size(Jason.encode!(host("slot-a")))
      assert length(Inventory.list_observations(context.scope)) == 1
    end
  end

  test "lost acknowledgement replay preserves receipt and provenance through terminal retry",
       context do
    params = host("receipt")
    {:ok, %{work: first, receipt: receipt}} = admit(context, params)

    {:ok, {replacement, _}} =
      Inventory.create_intake_api_key(context.scope, %{name: "replacement"})

    {:ok, replay} = admit(%{context | key: replacement}, params, %{max_units: 0, max_bytes: 0})
    assert replay.disposition == :duplicate
    assert replay.receipt == receipt
    assert Work.get(context.scope, first.id).original_key_id == context.key.id

    assert {:error, :idempotency_conflict} =
             admit(
               context,
               put_in(params, ["resources", Access.at(0), "attributes", "hostname"], "changed")
             )

    {:ok, claim} = claim(context)
    assert {:ok, {:ok, _resource, true}} = Work.execute_host(claim)
    assert lane(context).pending_units == 0
    assert lane(context).pending_bytes == 0
    assert {:error, :stale_claim} = Work.execute_host(claim)
    assert {:error, :stale_claim} = Work.fail(claim, :domain, %{"late" => true})

    assert {:error, :capacity} =
             Work.terminal_retry(context.scope, first.id, 0, %{
               max_units: 0,
               max_bytes: 0
             })

    assert {:ok, next} = Work.terminal_retry(context.scope, first.id, 0, @limits)
    assert next.position > first.position
    assert next.id != first.id
    assert next.original_key_id == first.original_key_id
    assert {next.units, next.bytes} == {first.units, first.bytes}
    assert Work.receipt(context.scope, first.observation_id) == receipt
    assert lane(context).pending_units == first.units

    assert {:error, :superseded} =
             Work.terminal_retry(context.scope, first.id, 0, @limits)

    assert {:error, :terminal_work} = Work.retry(context.scope, first.id, 0)
    assert lane(context).pending_units == first.units
  end

  test "every component of the claim fence prevents cross-work and stale mutation", context do
    {:ok, %{work: first}} = admit(context, host("fence-a"))
    {:ok, %{work: second}} = admit(context, host("fence-b"))
    {:ok, claim} = claim(context)
    assert claim.work_id == first.id

    for forged <- [
          %{claim | token: Ecto.UUID.generate()},
          %{claim | lane_version: claim.lane_version + 1},
          %{claim | work_id: second.id},
          %{claim | generation: claim.generation + 1},
          %{claim | checkpoint: claim.checkpoint + 1},
          %{claim | status: "quarantined"}
        ] do
      assert {:error, :stale_claim} = Work.execute_host(forged)
      assert {:error, :stale_claim} = Work.fail(forged, :domain, %{"forged" => true})
    end

    assert {:ok, :checkpointed} = Work.execute(claim, fn _, _ -> {:progress, :checkpointed} end)
    assert Work.get(context.scope, first.id).checkpoint == 1
    assert lane(context).pending_units == 2
    assert {:error, :stale_claim} = Work.fail(claim, :domain, %{"old_checkpoint" => true})
    {:ok, successor} = claim(context)
    assert successor.checkpoint == 1
    assert {:ok, {:ok, _, true}} = Work.execute_host(successor)
    assert {:error, :stale_claim} = Work.fail(claim, :backoff, %{})
    assert Work.get(context.scope, first.id).status == "succeeded"
    assert lane(context).pending_units == 1
  end

  test "expiry denies completion and failure without takeover, then rediscovery recovers",
       context do
    {:ok, %{work: work}} = admit(context, host("expiry"))
    {:ok, old} = claim(context, claim_ms: 30)
    await_expired!(context)
    assert {:error, :expired_claim} = Work.execute_host(old)
    assert {:error, :expired_claim} = Work.fail(old, :domain, %{"expired" => true})
    assert Work.get(context.scope, work.id).status == "pending"
    assert lane(context).pending_bytes == work.bytes

    # A new process uses only DB state; no notifier or in-memory lease survives.
    {:ok, successor} = concurrent(fn -> claim(context) end) |> Task.await()
    assert successor.token != old.token
    assert {:ok, {:ok, _, true}} = Work.execute_host(successor)
    assert {:error, :stale_claim} = Work.fail(old, :domain, %{"late" => true})
    assert lane(context).pending_units == 0
  end

  test "expiry after real host effects rolls canonical outcomes and accounting back", context do
    params = host("effect-expiry")
    {:ok, %{work: work}} = admit(context, params)
    {:ok, claim} = claim(context, claim_ms: 200)

    assert {:error, :expired_claim} =
             Work.execute(claim, fn scope, observation ->
               assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
               Repo.query!("SELECT pg_sleep(0.25)")
               {:complete, :too_late}
             end)

    assert Inventory.list_resources(context.scope) == []
    assert Inventory.list_observation_reconciliations(context.scope, work.observation_id) == []
    assert Work.get(context.scope, work.id).checkpoint == 0
    assert lane(context).pending_bytes == work.bytes
    assert Repo.get!(Observation, work.observation_id).payload == params
  end

  test "crash before bookkeeping leaves accepted work and no partial canonical success",
       context do
    {:ok, %{work: work}} = admit(context, host("crash"))
    {:ok, claim} = claim(context, claim_ms: 150)

    assert_raise RuntimeError, "injected before bookkeeping", fn ->
      Work.execute(claim, fn scope, observation ->
        assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
        raise "injected before bookkeeping"
      end)
    end

    assert Inventory.list_resources(context.scope) == []
    assert Inventory.list_observation_reconciliations(context.scope, work.observation_id) == []
    assert Work.get(context.scope, work.id).status == "pending"
    await_expired!(context)
    {:ok, successor} = concurrent(fn -> claim(context) end) |> Task.await()
    assert {:ok, {:ok, _, true}} = Work.execute_host(successor)
    assert lane(context).pending_units == 0
  end

  test "operator retry retains reservations/progress and invalidates old owners",
       context do
    {:ok, %{work: work}} = admit(context, host("repair"))
    {:ok, old} = claim(context)
    assert {:ok, :progress} = Work.execute(old, fn _, _ -> {:progress, :progress} end)
    {:ok, claim} = claim(context)
    assert {:ok, quarantined} = Work.fail(claim, :domain, %{"permanent" => "domain failure"})
    assert quarantined.quarantine_kind == "domain"
    assert {:ok, :idle} = claim(context)

    assert {:ok, _} = Inventory.revoke_intake_api_key(context.scope, context.key.id)
    assert {:ok, :idle} = claim(context)
    assert Work.get(context.scope, work.id) == quarantined
    assert lane(context).pending_bytes == work.bytes
    assert {:error, :stale_claim} = Work.fail(claim, :backoff, %{})
    assert {:ok, repaired} = Work.retry(context.scope, work.id, 0)
    assert repaired.generation == 1
    assert repaired.checkpoint == 1
    assert {:error, :stale_work} = Work.retry(context.scope, work.id, 0)

    assert {repaired.units, repaired.bytes, repaired.position} ==
             {work.units, work.bytes, work.position}

    {:ok, successor} = claim(context)
    assert {:ok, {:ok, _, true}} = Work.execute_host(successor)
    assert lane(context).pending_bytes == 0

    assert Enum.count(
             Inventory.list_activity(context.scope),
             &(&1.field == "reconciliation_retry")
           ) == 1
  end

  for removal <- [:revoke, :delete, :agent_delete] do
    @removal removal
    test "accepted work survives #{@removal} but fresh intake cannot use removed credentials",
         context do
      {:ok, %{work: work, receipt: receipt}} = admit(context, host("accepted"))

      case @removal do
        :revoke ->
          assert {:ok, _} = Inventory.revoke_intake_api_key(context.scope, context.key.id)

        :delete ->
          Repo.delete!(context.key)

        :agent_delete ->
          Repo.delete!(context.agent)
      end

      assert {:error, :authority_unavailable} = admit(context, host("new"))
      assert Work.receipt(context.scope, work.observation_id) == receipt
      {:ok, claim} = claim(context)
      assert {:ok, {:ok, resource, true}} = Work.execute_host(claim)
      assert resource.organization_id == context.scope.organization_id
      assert lane(context).pending_units == 0
      done = Work.get(context.scope, work.id)

      assert {done.original_key_id, done.installation_agent_id, done.installation_id} ==
               {context.key.id, context.agent.id, context.installation_id}

      assert done.status == "succeeded"
      assert {:ok, next} = Work.terminal_retry(context.scope, work.id, 0, @limits)
      assert next.original_key_id == context.key.id
      assert lane(context).pending_bytes == work.bytes
    end
  end

  test "explicit retries recheck current human permission without historical credentials",
       context do
    {:ok, %{work: work}} = admit(context, host("fresh-human"))

    membership =
      Repo.get_by!(Accounts.OrganizationMembership,
        organization_id: context.scope.organization_id,
        user_id: context.scope.user.id
      )

    assert {:ok, _} = Accounts.update_organization_membership(membership, %{role: "viewer"})
    assert {:error, :forbidden} = Work.retry(context.scope, work.id, 0)
    assert {:error, :forbidden} = Work.terminal_retry(context.scope, work.id, 0, @limits)

    assert {:error, :forbidden} =
             Work.retry(Accounts.scope_for(context.scope.organization), work.id, 0)

    assert Work.get(context.scope, work.id).generation == 0

    refute Repo.exists?(
             from event in ChangeEvent,
               where:
                 event.organization_id == ^context.scope.organization_id and
                   event.field == "reconciliation_retry"
           )
  end

  @tag :tmp_dir
  test "opaque scoped roots reserve declared units without materializing or finalizing",
       context do
    source =
      Repo.insert!(%Inventory.Source{
        organization_id: context.scope.organization_id,
        agent_id: context.agent.id,
        collector_id: "switches",
        kind: "switch_poller",
        name: "Opaque stream",
        status: "active"
      })

    params = %{
      "observation_id" => "opaque",
      "observed_at" => "2026-10-30T00:00:00Z",
      "scope" => "targets",
      "collector" => %{"id" => "switches", "kind" => "switch_poller"},
      "complete" => true,
      "targets" => Enum.map(1..3, &%{"address" => "10.0.0.#{&1}", "status" => "reachable"}),
      "resources" =>
        Enum.map(
          1..2,
          &%{
            "kind" => "switch",
            "target" => "10.0.0.#{&1}",
            "identifiers" => %{"serial_number" => "serial-#{&1}"},
            "interfaces" => []
          }
        )
    }

    assert {:ok, %{work: work}} =
             Work.admit(
               context.scope,
               context.key,
               context.installation_id,
               source.id,
               params,
               @limits
             )

    assert work.units == 6
    assert work.bytes == 995
    assert lane(context).pending_units == 6
    assert Inventory.list_derived_observations(context.scope, work.observation_id) == []
    {:ok, claim} = claim(context)
    assert {:error, :unsupported_execution} = Work.execute_host(claim)
    assert Inventory.list_resources(context.scope) == []
    assert Inventory.Collectors.list_targets(context.scope, source.id) == []
    assert Inventory.list_observation_reconciliations(context.scope, work.observation_id) == []

    assert Inventory.CollectionClocks.by_source(context.scope)[source.id].reconciled_observed_at ==
             nil

    assert Work.get(context.scope, work.id).checkpoint == 0
    assert lane(context).pending_bytes == work.bytes

    assert {:error, :unsupported_processing_state} =
             Export.write(
               context.scope.organization,
               Path.join(context.tmp_dir, "opaque.tar.zst")
             )
  end

  @tag :tmp_dir
  test "transfer rejects outstanding states but permits drained history", context do
    path = Path.join(context.tmp_dir, "guard.tar.zst")
    export = fn -> Export.write(context.scope.organization, path, parts: ["raw_observations"]) end
    assert {:ok, _} = export.()
    File.rm!(path)

    # This earlier drained preflight cannot authorize the later snapshot.
    {:ok, %{work: work}} = concurrent(fn -> admit(context, host("transfer")) end) |> Task.await()
    assert {:error, :unsupported_processing_state} = export.()
    refute File.exists?(path)
    {:ok, owner} = claim(context)
    assert {:ok, :chunk} = Work.execute(owner, fn _, _ -> {:progress, :chunk} end)
    assert {:error, :unsupported_processing_state} = export.()
    {:ok, owner} = claim(context)
    assert {:ok, _} = Work.fail(owner, :backoff, %{}, backoff_ms: 60_000)
    assert {:error, :unsupported_processing_state} = export.()
    assert {:ok, _} = Work.retry(context.scope, work.id, 0)
    {:ok, owner} = claim(context)
    assert {:ok, _} = Work.fail(owner, :domain, %{})
    assert {:error, :unsupported_processing_state} = export.()
    assert {:ok, _} = Work.retry(context.scope, work.id, 1)
    assert {:error, :unsupported_processing_state} = export.()
    {:ok, owner} = claim(context)
    assert {:ok, {:ok, _, true}} = Work.execute_host(owner)
    assert {:ok, _} = export.()

    {:ok, archive} = Archive.open(path, tmp_dir: context.tmp_dir)

    try do
      refute "reconciliation_work" in Archive.record_types(archive)
      refute "reconciliation_lanes" in Archive.record_types(archive)
      assert [%{"id" => observation_id}] = Enum.to_list(Archive.records(archive, "observations"))
      assert observation_id == work.observation_id
    after
      Archive.close(archive)
    end

    # Even inconsistent residual accounting must not be silently dropped.
    File.rm!(path)

    for residual <- [
          [pending_units: 1],
          [pending_bytes: 1],
          [token: Ecto.UUID.generate(), work_id: work.id, expires_at: DateTime.utc_now()]
        ] do
      Repo.update_all(
        from(lane in ReconciliationLane,
          where: lane.organization_id == ^context.scope.organization_id
        ),
        set: Keyword.merge([pending_units: 0, pending_bytes: 0], residual)
      )

      assert {:error, :unsupported_processing_state} = export.()
      refute File.exists?(path)
    end
  end

  @tag :tmp_dir
  test "acceptance after the export snapshot cannot tear or authorize the next snapshot",
       context do
    previous = Application.get_env(:renga, Export)
    Application.put_env(:renga, Export, repeatable_read: true)
    on_exit(fn -> Application.put_env(:renga, Export, previous) end)
    path = Path.join(context.tmp_dir, "snapshot.tar.zst")

    write = fn
      "addressing_plan_levels" ->
        assert {:ok, _} =
                 concurrent(fn -> admit(context, host("late-transfer")) end) |> Task.await()

      _type ->
        :ok
    end

    assert {:ok, _} =
             Export.write(context.scope.organization, path,
               parts: ["raw_observations"],
               after_record_type: write
             )

    {:ok, archive} = Archive.open(path, tmp_dir: context.tmp_dir)

    try do
      assert Enum.to_list(Archive.records(archive, "observations")) == []
      assert :ok = Renga.Transfers.Validation.validate(archive)
    after
      Archive.close(archive)
    end

    assert Repo.exists?(
             from work in Work, where: work.organization_id == ^context.scope.organization_id
           )

    assert {:error, :unsupported_processing_state} =
             Export.write(context.scope.organization, Path.join(context.tmp_dir, "next.tar.zst"))
  end

  test "quarantined or delayed heads block later work before the candidate limit", context do
    # More blocked organizations than the one-candidate limit, each with a
    # later ready row. Filtering pending/due before MIN(position) leaks them.
    for index <- 1..3 do
      blocked = other_installation()
      {:ok, _} = admit(blocked, host("blocked-head-#{index}"))
      {:ok, _} = admit(blocked, host("blocked-tail-#{index}"))
      {:ok, claim} = claim(blocked)

      if index == 1 do
        assert {:ok, _} = Work.fail(claim, :backoff, %{}, backoff_ms: 60_000)
      else
        assert {:ok, _} = Work.fail(claim, :domain, %{"blocked" => true})
      end
    end

    {:ok, %{work: quiet}} = admit(context, host("quiet"))
    {:ok, first} = claim(context)
    assert {:ok, :progress} = Work.execute(first, fn _, _ -> {:progress, :progress} end)
    # This lane has the newest last_turn_at, so the blocked lanes would win
    # under an incorrectly filtered head query.
    assert {:ok, %{work_id: work_id}} = concurrent(fn -> Work.claim_next() end) |> Task.await()
    assert work_id == quiet.id
  end

  test "scheduler skips an organization locked by a noisy neighbor", context do
    {:ok, _} = admit(context, host("locked-neighbor"))
    quiet = other_installation()
    {:ok, %{work: expected}} = admit(quiet, host("quiet-neighbor"))
    Repo.query!("BEGIN")

    Repo.query!(
      "SELECT id FROM organizations WHERE id = $1 FOR UPDATE",
      [Ecto.UUID.dump!(context.scope.organization_id)]
    )

    try do
      assert {:ok, %{work_id: work_id}} =
               concurrent(fn -> Work.claim_next() end) |> Task.await(1_000)

      assert work_id == expected.id
    after
      Repo.query!("ROLLBACK")
    end
  end

  test "failed hot turns advance persistent scheduling state across a new process", context do
    {:ok, _} = admit(context, host("hot"))
    quiet = other_installation()
    {:ok, %{work: quiet_work}} = admit(quiet, host("quiet"))
    {:ok, quiet_claim} = claim(quiet)
    assert {:ok, :progress} = Work.execute(quiet_claim, fn _, _ -> {:progress, :progress} end)
    quiet_turn = lane(quiet).last_turn_at
    {:ok, hot_claim} = claim(context, claim_ms: 150)
    assert DateTime.compare(lane(context).last_turn_at, quiet_turn) == :gt
    assert {:error, :injected} = Work.execute(hot_claim, fn _, _ -> {:error, :injected} end)
    await_expired!(context)
    assert {:ok, %{work_id: work_id}} = concurrent(fn -> Work.claim_next() end) |> Task.await()
    assert work_id == quiet_work.id
  end

  test "directly locked lanes are skipped before the candidate limit", context do
    blocked =
      for index <- 1..3 do
        fixture = other_installation()
        {:ok, _} = admit(fixture, host("locked-lane-#{index}"))
        fixture
      end

    {:ok, %{work: expected}} = admit(context, host("quiet-lane"))
    {:ok, initial} = claim(context)
    assert {:ok, :progress} = Work.execute(initial, fn _, _ -> {:progress, :progress} end)
    Repo.query!("BEGIN")

    for fixture <- blocked do
      Repo.query!(
        "SELECT organization_id FROM reconciliation_lanes WHERE organization_id = $1 FOR UPDATE",
        [Ecto.UUID.dump!(fixture.scope.organization_id)]
      )
    end

    try do
      assert {:ok, %{work_id: work_id}} =
               concurrent(fn -> Work.claim_next() end) |> Task.await(1_000)

      assert work_id == expected.id
    after
      Repo.query!("ROLLBACK")
    end
  end

  for locked <- [:source, :work, :advisory] do
    @locked locked
    test "busy #{@locked} rotates across restart without changing work", context do
      {:ok, %{work: work}} = admit(context, host("busy"))
      quiet = other_installation()
      {:ok, %{work: quiet_work}} = admit(quiet, host("quiet"))
      before_lane = lane(context)
      Repo.query!("BEGIN")

      case @locked do
        :advisory ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            context.scope.organization_id
          ])

        row ->
          {table, id} =
            Map.fetch!(
              %{
                source: {"sources", context.agent.source_id},
                work: {"reconciliation_work", work.id}
              },
              row
            )

          Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(id)])
      end

      try do
        assert {:ok, :busy} = concurrent(fn -> claim(context) end) |> Task.await(1_000)
        assert lane(context).last_turn_at != nil
        assert Map.delete(lane(context), :last_turn_at) == Map.delete(before_lane, :last_turn_at)
        assert Work.get(context.scope, work.id) == work

        assert {:ok, %{work_id: next_id}} =
                 concurrent(fn -> Work.claim_next() end) |> Task.await(1_000)

        assert next_id == quiet_work.id
      after
        Repo.query!("ROLLBACK")
      end

      {:ok, recovered} = claim(context)
      assert {:ok, {:ok, _, true}} = Work.execute_host(recovered)
      assert lane(context).pending_units == 0
    end
  end

  test "competing claims cannot share a single organization's turn", context do
    {:ok, %{work: work}} = admit(context, host("claim-race"))
    tasks = for _ <- 1..2, do: concurrent(fn -> claim(context) end)
    results = Task.await_many(tasks)
    assert Enum.count(results, &match?({:ok, %{work_id: _}}, &1)) == 1
    assert {:ok, :idle} in results
    {:ok, owner} = Enum.find(results, &match?({:ok, %{work_id: _}}, &1))
    assert owner.work_id == work.id
    assert {:ok, {:ok, _, true}} = Work.execute_host(owner)
    assert lane(context).pending_units == 0
  end

  test "statement cancellation rolls back effects but allows fenced failure bookkeeping",
       context do
    {:ok, %{work: work}} = admit(context, host("statement-timeout"))
    {:ok, claim} = claim(context)

    error =
      assert_raise Postgrex.Error, fn ->
        Work.execute(
          claim,
          fn scope, observation ->
            assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
            Repo.query!("SELECT pg_sleep(0.2)")
            {:complete, :unreachable}
          end,
          statement_ms: 50
        )
      end

    assert error.postgres.code == :query_canceled
    assert Inventory.list_resources(context.scope) == []
    assert Inventory.list_observation_reconciliations(context.scope, work.observation_id) == []
    assert {:ok, parked} = Work.fail(claim, :domain, %{"sql" => "cancelled"})
    assert parked.status == "quarantined"
    assert parked.checkpoint == 0
    assert lane(context).pending_bytes == work.bytes
  end

  test "outer deadline terminates many short statements and replacement connection rediscovery",
       context do
    {:ok, %{work: work}} = admit(context, host("outer-timeout"))
    {:ok, claim} = claim(context, claim_ms: 1_000)

    outcome =
      try do
        Work.execute(
          claim,
          fn scope, observation ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(self(), {:turn_backend, backend})
            assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
            for _ <- 1..30, do: Repo.query!("SELECT pg_sleep(0.01)")
            {:complete, :unreachable}
          end,
          statement_ms: 100,
          transaction_ms: 200
        )
      rescue
        exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:terminated, exception}
      end

    assert {:terminated, _} = outcome
    assert_receive {:turn_backend, old_backend}
    Sandbox.checkin(Repo)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    [[new_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    refute old_backend == new_backend
    assert Inventory.list_resources(context.scope) == []
    assert Inventory.list_observation_reconciliations(context.scope, work.observation_id) == []
    assert Work.get(context.scope, work.id).status == "pending"
    assert lane(context).pending_bytes == work.bytes
    await_expired!(context)
    {:ok, successor} = concurrent(fn -> claim(context) end) |> Task.await()
    assert {:ok, {:ok, _, true}} = Work.execute_host(successor)
    assert lane(context).pending_units == 0
  end

  test "durable operations reject caller-owned transactions before mutation", context do
    assert_raise ArgumentError, "durable work requires a top-level transaction", fn ->
      Repo.transaction(fn -> admit(context, host("nested")) end)
    end

    assert Inventory.list_observations(context.scope) == []
    {:ok, %{work: work}} = admit(context, host("top-level"))
    {:ok, claim} = claim(context)

    assert_raise ArgumentError, "durable work requires a top-level transaction", fn ->
      Repo.transaction(fn -> Work.execute_host(claim) end)
    end

    assert Work.get(context.scope, work.id).checkpoint == 0
    assert Inventory.list_resources(context.scope) == []
  end

  test "suspension denies claims, publication, failure and retries without losing charge",
       context do
    {:ok, %{work: work}} = admit(context, host("suspended"))
    {:ok, owner} = claim(context)

    assert {:ok, _} =
             Accounts.update_organization(context.scope.organization, %{status: "disabled"})

    assert {:ok, :idle} = claim(context)
    assert {:error, :forbidden} = Work.execute_host(owner)
    assert {:error, :forbidden} = Work.fail(owner, :domain, %{})
    assert {:error, :forbidden} = Work.retry(context.scope, work.id, 0)
    assert {:error, :forbidden} = Work.terminal_retry(context.scope, work.id, 0, @limits)
    assert {:error, :forbidden} = admit(context, host("new"))
    assert Work.get(context.scope, work.id) == work
    assert lane(context).pending_bytes == work.bytes
    assert Inventory.list_resources(context.scope) == []
  end

  test "admission waiting behind key revocation rechecks after the actual lock race", context do
    Repo.query!("BEGIN")

    Repo.query!("UPDATE intake_api_keys SET status = 'revoked' WHERE id = $1", [
      Ecto.UUID.dump!(context.key.id)
    ])

    parent = self()

    task =
      concurrent(fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:admission_backend, backend})
        admit(context, host("revocation-race"))
      end)

    try do
      assert_receive {:admission_backend, backend}, 1_000
      await_lock!(backend)
    after
      Repo.query!("COMMIT")
    end

    assert {:error, :authority_unavailable} = Task.await(task)
    assert Inventory.list_observations(context.scope) == []
    assert Repo.get(ReconciliationLane, context.scope.organization_id) == nil
  end

  test "hypervisor root reserves its declared target without creating children", context do
    source =
      Repo.insert!(%Inventory.Source{
        organization_id: context.scope.organization_id,
        agent_id: context.agent.id,
        collector_id: "hypervisor",
        kind: "vm_provider",
        name: "Opaque hypervisor",
        status: "active"
      })

    params = %{
      "observation_id" => "hypervisor",
      "observed_at" => "2026-10-30T00:00:00Z",
      "scope" => "hypervisor",
      "collector" => %{"id" => "hypervisor", "kind" => "vm_provider"},
      "hypervisor" => %{"id" => "hv-1", "status" => "reachable"},
      "resources" => []
    }

    assert {:error, :capacity} =
             Work.admit(context.scope, context.key, context.installation_id, source.id, params, %{
               max_units: 1,
               max_bytes: 1_000_000
             })

    assert Inventory.list_observations(context.scope) == []

    assert {:ok, %{work: work}} =
             Work.admit(context.scope, context.key, context.installation_id, source.id, params, %{
               max_units: 2,
               max_bytes: 1_000_000
             })

    assert work.units == 2
    assert Inventory.list_derived_observations(context.scope, work.observation_id) == []
    {:ok, owner} = claim(context)
    assert {:error, :unsupported_execution} = Work.execute_host(owner)
    assert lane(context).pending_units == 2
  end

  for state <- [:pending, :quarantined, :succeeded] do
    @state state
    test "retained #{@state} work/evidence and idle or active lane cannot be deleted", context do
      {:ok, %{work: work, receipt: receipt}} = admit(context, host("retention"))
      {:ok, owner} = claim(context)

      case @state do
        :pending -> :ok
        :quarantined -> assert {:ok, _} = Work.fail(owner, :domain, %{"retained" => true})
        :succeeded -> assert {:ok, {:ok, _, true}} = Work.execute_host(owner)
      end

      for {table, column, id} <- [
            {"reconciliation_work", "id", work.id},
            {"observations", "id", work.observation_id},
            {"reconciliation_lanes", "organization_id", work.organization_id}
          ] do
        assert_raise Postgrex.Error, fn ->
          Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [Ecto.UUID.dump!(id)])
        end
      end

      assert Work.receipt(context.scope, work.observation_id) == receipt

      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE reconciliation_work SET original_key_id = $1 WHERE id = $2",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(work.id)]
        )
      end

      Repo.delete!(context.scope.organization)
      refute Repo.get(Work, work.id)
      refute Repo.get(ReconciliationLane, work.organization_id)
      refute Repo.get(Observation, work.observation_id)
    end
  end

  test "database tenant references, lease shape and monotone lane history fail closed", context do
    {:ok, %{work: work}} = admit(context, host("own"))
    other = other_installation()
    {:ok, %{work: alien}} = admit(other, host("alien"))
    {:ok, owner} = claim(context)
    before_lane = lane(context)

    for {sql, params} <- [
          {"UPDATE reconciliation_lanes SET work_id = $1 WHERE organization_id = $2",
           [alien.id, work.organization_id]},
          {"UPDATE reconciliation_lanes SET organization_id = $1 WHERE organization_id = $2",
           [other.scope.organization_id, work.organization_id]},
          {"UPDATE reconciliation_lanes SET token = NULL WHERE organization_id = $1",
           [work.organization_id]},
          {"UPDATE reconciliation_lanes SET version = 0 WHERE organization_id = $1",
           [work.organization_id]},
          {"UPDATE reconciliation_lanes SET position = 0 WHERE organization_id = $1",
           [work.organization_id]},
          {"UPDATE reconciliation_lanes SET last_turn_at = NULL WHERE organization_id = $1",
           [work.organization_id]},
          {"UPDATE reconciliation_lanes SET pending_bytes = -1 WHERE organization_id = $1",
           [work.organization_id]}
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.query!(sql, Enum.map(params, &Ecto.UUID.dump!/1))
      end

      assert lane(context) == before_lane
    end

    forged = %{work | id: Ecto.UUID.generate(), observation_id: alien.observation_id, position: 2}
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(forged) end
    assert {:ok, {:ok, _, true}} = Work.execute_host(owner)
    assert lane(context).pending_units == 0
  end

  test "deletion of a key during a host turn cannot revoke accepted processing", context do
    {:ok, %{work: work}} = admit(context, host("delete-during"))
    {:ok, owner} = claim(context)
    parent = self()

    task =
      concurrent(fn ->
        receive do
          :delete -> :ok
        end

        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:deleting_backend, backend})
        Repo.delete!(context.key)
        send(parent, :key_deleted)
      end)

    assert {:ok, :done} =
             Work.execute(owner, fn scope, observation ->
               assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
               send(task.pid, :delete)
               assert_receive {:deleting_backend, backend}, 1_000
               # The core's evidence FK locks can serialize SET NULL on that
               # observation. No submitting-key/Agent row lock gates the turn.
               await_lock!(backend)

               assert [[0]] =
                        Repo.query!(
                          "SELECT count(*) FROM pg_locks WHERE pid = pg_backend_pid() AND relation IN ('intake_api_keys'::regclass, 'agents'::regclass) AND mode = 'RowShareLock'"
                        ).rows

               {:complete, :done}
             end)

    Task.await(task)
    assert_receive :key_deleted, 1_000
    assert Repo.get!(Observation, work.observation_id).intake_api_key_id == nil
    assert Work.get(context.scope, work.id).original_key_id == context.key.id
    assert lane(context).pending_units == 0
  end

  test "live-key nullification cannot rewrite immutable observation payload", context do
    {:ok, %{work: work}} = admit(context, host("immutable"))

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE observations SET intake_api_key_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(work.observation_id)]
      )
    end

    Repo.delete!(context.key)

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE observations SET payload = '{}'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(work.observation_id)]
      )
    end

    assert Repo.get!(Observation, work.observation_id).payload == host("immutable")
    assert Work.get(context.scope, work.id).original_key_id == context.key.id
  end

  test "sync-run deletion exception cannot smuggle an arbitrary key replacement", context do
    {:ok, run} = Inventory.create_sync_run(context.scope, context.agent.source_id)

    {:ok, {replacement, _}} =
      Inventory.create_intake_api_key(context.scope, %{name: "replacement"})

    {:ok, observation, :created} =
      Inventory.accept_observation(context.scope, context.agent.source_id, %{
        idempotency_key: "sync-key",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"immutable" => true},
        sync_run_id: run.id,
        intake_api_key_id: context.key.id
      })

    # Real FK nullification invokes this earlier BEFORE trigger. The immutable
    # trigger must reject the changed key even though the sync-run parent is gone.
    Repo.query!("""
    CREATE FUNCTION pg_temp.replace_observation_key() RETURNS trigger AS $$
    BEGIN
      IF OLD.id = '#{observation.id}'::uuid THEN
        NEW.intake_api_key_id := '#{replacement.id}'::uuid;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER a_test_replace_observation_key BEFORE UPDATE ON observations FOR EACH ROW EXECUTE FUNCTION pg_temp.replace_observation_key()"
    )

    try do
      assert_raise Postgrex.Error, fn -> Repo.delete!(run) end
      assert Repo.get!(Observation, observation.id).intake_api_key_id == context.key.id
      assert Repo.get!(Observation, observation.id).sync_run_id == run.id
    after
      Repo.query!("DROP TRIGGER a_test_replace_observation_key ON observations")
      Repo.query!("DROP FUNCTION pg_temp.replace_observation_key()")
    end

    Repo.delete!(run)
    assert Repo.get!(Observation, observation.id).sync_run_id == nil
    assert Repo.get!(Observation, observation.id).intake_api_key_id == context.key.id
  end

  test "backend termination after effects rolls back and is rediscovered on a replacement connection",
       context do
    {:ok, %{work: work}} = admit(context, host("backend-loss"))
    {:ok, owner} = claim(context, claim_ms: 500)
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows

    killer =
      concurrent(fn ->
        receive do
          :terminate -> :ok
        end

        assert [[true]] = Repo.query!("SELECT pg_terminate_backend($1)", [backend]).rows
      end)

    outcome =
      try do
        Work.execute(owner, fn scope, observation ->
          assert {:ok, _, true} = Reconciler.reconcile_in_transaction(scope, observation)
          send(killer.pid, :terminate)
          Task.await(killer)

          lost =
            try do
              Repo.query!("SELECT 1")
            rescue
              exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:lost, exception}
            end

          assert {:lost, _} = lost
          # Even a callback swallowing the connection loss cannot publish on a
          # replacement connection or turn its rolled-back effects into success.
          {:complete, :swallowed_disconnect}
        end)
      rescue
        exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:terminated, exception}
      end

    assert {:terminated, _} = outcome

    Sandbox.checkin(Repo)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert Inventory.list_resources(context.scope) == []
    assert Work.get(context.scope, work.id).checkpoint == 0
    assert lane(context).pending_bytes == work.bytes
    await_expired!(context)
    {:ok, recovered} = claim(context)
    assert {:ok, {:ok, _, true}} = Work.execute_host(recovered)
    assert lane(context).pending_bytes == 0
  end

  for recovery <- [:deletion, :limit_increase] do
    @tag recovery: recovery
    test "quota deferral retains one retry and reservation across restart and #{recovery}",
         context do
      recovery = context.recovery
      set_resource_quota!(context, 1)

      {:ok, occupied} =
        Inventory.create_resource(context.scope, %{kind: "server", name: "occupied"})

      params = host("quota-restart")
      {:ok, %{work: work, receipt: receipt}} = admit(context, params)

      for generation <- 0..1 do
        if generation > 0, do: make_quota_due!(context, work)

        assert {:ok, {:error, %{status: "failed", errors: errors}}} =
                 Renga.Inventory.ReconciliationWorker.run_once(
                   organization_id: context.scope.organization_id
                 )

        assert errors == %{"processing" => "quota_deferred", "quota" => "resources"}
        deferred = Work.get(context.scope, work.id)
        assert deferred.status == "quota_deferred"
        assert deferred.generation == generation
        assert deferred.checkpoint == 0
        assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 1
        assert Renga.Quotas.usage(context.scope.organization_id, :resources) == 1
        assert lane(context).pending_units == work.units
        assert lane(context).pending_bytes == work.bytes
        assert Work.receipt(context.scope, work.observation_id) == receipt
        assert {:ok, %{receipt: ^receipt, disposition: :duplicate}} = admit(context, params)
      end

      assert Enum.map(
               Inventory.list_observation_reconciliations(context.scope, work.observation_id),
               & &1.attempt
             ) == [1, 2]

      case recovery do
        :deletion -> Repo.delete!(occupied)
        :limit_increase -> set_resource_quota!(context, 2)
      end

      make_quota_due!(context, work)
      Sandbox.checkin(Repo)
      Sandbox.mode(Repo, :auto)
      {:ok, worker} = Renga.Inventory.ReconciliationWorker.start_link(name: nil, interval: 10)

      try do
        await_succeeded!(context, work.id)
        assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 0
        assert Work.get(context.scope, work.id).generation == 2
        assert Work.receipt(context.scope, work.observation_id) == receipt
        assert Repo.get!(Observation, work.observation_id).payload == params
        assert Repo.aggregate(Work, :count) == 1
        assert lane(context).pending_units == 0
        assert lane(context).pending_bytes == 0
        expected_usage = if recovery == :deletion, do: 1, else: 2
        assert Renga.Quotas.usage(context.scope.organization_id, :resources) == expected_usage

        assert Repo.aggregate(
                 from(event in ChangeEvent,
                   where:
                     event.organization_id == ^context.scope.organization_id and
                       event.field == "reconciliation_quota_retry"
                 ),
                 :count
               ) == 2
      after
        GenServer.stop(worker)
        Sandbox.mode(Repo, :manual)
        :ok = Sandbox.checkout(Repo, sandbox: false)
      end
    end
  end

  test "exact report dispatch cannot switch to an older deferral that becomes due", context do
    {:ok, %{work: older}} = admit(context, host("older-boundary"))
    {:ok, older_claim} = claim(context)
    assert {:ok, _} = Work.fail(older_claim, :quota, %{}, backoff_ms: 60_000)
    {:ok, %{work: requested}} = admit(context, host("requested-boundary"))
    before_events = Repo.aggregate(ChangeEvent, :count)
    parent = self()
    handler = "exact-dispatch-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:renga, :repo, :query],
      fn _, _, metadata, {parent, handler} ->
        # Pause after candidate selection, before the first clock-sensitive
        # head reread. Only this dispatch task participates in the barrier.
        if Process.get(handler) && String.ends_with?(metadata.query, "SKIP LOCKED") do
          send(parent, {:candidate_selected, self()})

          receive do
            {:continue_dispatch, ^handler} -> :ok
          after
            5_000 -> raise "dispatch barrier was not released"
          end
        end
      end,
      {parent, handler}
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    dispatch =
      concurrent(fn ->
        Process.put(handler, true)
        Inventory.reconcile_observation_once(context.scope, requested.observation_id)
      end)

    assert_receive {:candidate_selected, caller}, 1_000
    make_quota_due!(context, older)
    send(caller, {:continue_dispatch, handler})
    assert {:error, :head_changed} = Task.await(dispatch)
    assert Work.get(context.scope, requested.id).status == "pending"
    assert %{status: "quota_deferred", generation: 0} = Work.get(context.scope, older.id)
    assert Repo.aggregate(ChangeEvent, :count) == before_events
    assert Inventory.list_resources(context.scope) == []
    assert {:ok, %{work_id: id, generation: 1}} = claim(context)
    assert id == older.id
  end

  test "quota delays permit matching updates; an older retry cannot overwrite newer evidence",
       context do
    set_resource_quota!(context, 0)

    old =
      put_in(host("older"), ["resources", Access.at(0), "identifiers", "machine_id"], "same-host")

    {:ok, %{work: deferred}} = admit(context, old)

    assert {:ok, {:error, %{status: "failed"}}} =
             Renga.Inventory.ReconciliationWorker.run_once(
               organization_id: context.scope.organization_id
             )

    set_resource_quota!(context, 1)

    newer =
      old
      |> Map.put("observation_id", "newer")
      |> Map.put("observed_at", "2026-10-31T00:00:00Z")
      |> put_in(["resources", Access.at(0), "attributes", "hostname"], "newer")

    {:ok, %{work: newest}} = admit(context, newer)

    assert {:ok, {:ok, resource, true}} =
             Renga.Inventory.ReconciliationWorker.run_once(
               organization_id: context.scope.organization_id
             )

    assert Work.get(context.scope, newest.id).status == "succeeded"
    assert Work.get(context.scope, deferred.id).status == "quota_deferred"
    observation = Inventory.get_observation!(context.scope, deferred.observation_id)
    make_quota_due!(context, deferred)

    assert {:error, %{errors: %{"processing" => "quota_deferred"}}} =
             Reconciler.reconcile_once(context.scope, observation)

    assert Work.get(context.scope, deferred.id).generation == 0
    # Move the next pass back out while exercising the no-growth update.
    Work.get(context.scope, deferred.id)
    |> Ecto.Changeset.change(run_after: DateTime.add(Renga.Time.utc_now_ms(), 30))
    |> Repo.update!()

    # New evidence that needs no envelope remains executable at the full quota.
    update = Map.put(newer, "observation_id", "at-capacity-update")
    {:ok, _} = admit(context, update)

    assert {:ok, {:ok, same_resource, false}} =
             Renga.Inventory.ReconciliationWorker.run_once(
               organization_id: context.scope.organization_id
             )

    assert same_resource.id == resource.id
    make_quota_due!(context, deferred)
    {:ok, %{work: later}} = admit(context, host("later-arrival"))
    assert {:ok, claim} = claim(context)
    assert claim.work_id == deferred.id
    assert claim.generation == 1
    assert {:ok, {:ok, matched, false}} = Work.execute_report(claim)
    assert matched.id == resource.id
    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "newer"
    assert Work.get(context.scope, later.id).status == "pending"
    assert Renga.Quotas.usage(context.scope.organization_id, :resources) == 1
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 0
    assert lane(context).pending_bytes == later.bytes
  end

  test "a later report member hitting quota rolls back all members before durable deferral",
       context do
    # A deployment default, not an org override: the failed first report also
    # rolls back the first resources usage row. The retry must establish zero.
    [[previous]] =
      Repo.query!("SELECT value FROM organization_quota_defaults WHERE name = 'resources'").rows

    Repo.query!("UPDATE organization_quota_defaults SET value = 1 WHERE name = 'resources'")

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.query!("UPDATE organization_quota_defaults SET value = $1 WHERE name = 'resources'", [
        previous
      ])

      Sandbox.checkin(Repo)
    end)

    assert Repo.query!(
             "SELECT used FROM organization_quota_usage WHERE organization_id = $1 AND name = 'resources'",
             [Ecto.UUID.dump!(context.scope.organization_id)]
           ).rows == []

    source =
      Repo.insert!(%Inventory.Source{
        organization_id: context.scope.organization_id,
        agent_id: context.agent.id,
        collector_id: "quota-switches",
        kind: "switch_poller",
        name: "Quota stream",
        status: "active"
      })

    params = %{
      "observation_id" => "quota-report",
      "observed_at" => "2026-10-30T00:00:00Z",
      "scope" => "targets",
      "collector" => %{"id" => "quota-switches", "kind" => "switch_poller"},
      "complete" => true,
      "targets" => Enum.map(1..2, &%{"address" => "10.0.0.#{&1}", "status" => "reachable"}),
      "resources" =>
        Enum.map(
          1..2,
          &%{
            "kind" => "switch",
            "target" => "10.0.0.#{&1}",
            "identifiers" => %{"serial_number" => "quota-#{&1}"},
            "interfaces" => []
          }
        )
    }

    {:ok, %{work: work}} =
      Work.admit(context.scope, context.key, context.installation_id, source.id, params, @limits)

    assert {:ok, {:error, %{errors: %{"processing" => "quota_deferred"}}}} =
             Renga.Inventory.ReconciliationWorker.run_once(
               organization_id: context.scope.organization_id
             )

    assert Inventory.list_resources(context.scope) == []
    assert Inventory.list_derived_observations(context.scope, work.observation_id) == []
    assert Inventory.Collectors.list_targets(context.scope, source.id) == []
    assert Renga.Quotas.usage(context.scope.organization_id, :resources) == 0
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 1

    finding =
      Repo.get_by!(Renga.Quotas.Finding,
        organization_id: context.scope.organization_id,
        name: "resources"
      )

    assert finding.used == 0
    assert finding.capacity == 1
    assert finding.resolved_at == nil
    assert lane(context).pending_units == work.units
    assert lane(context).pending_bytes == work.bytes
    set_resource_quota!(context, 2)
    make_quota_due!(context, work)

    assert {:ok, {:ok, resources, true}} =
             Renga.Inventory.ReconciliationWorker.run_once(
               organization_id: context.scope.organization_id
             )

    assert length(resources) == 2
    assert Renga.Quotas.usage(context.scope.organization_id, :resources) == 2
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 0
    assert lane(context).pending_units == 0
    assert lane(context).pending_bytes == 0
  end

  test "quota retry items survive transient errors but not non-quota terminal results", context do
    {:ok, %{work: work}} = admit(context, host("quota-lifecycle"))
    {:ok, claim} = claim(context)
    error = %{"processing" => "quota_deferred", "quota" => "resources"}
    assert {:ok, _} = Work.fail(claim, :quota, error)
    assert {:error, :stale_claim} = Work.fail(claim, :quota, error)
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 1
    {:ok, claim} = claim(context)
    assert claim.generation == 1
    assert {:ok, _} = Work.fail(claim, :backoff, %{"processing" => "projection_failed"})
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 1
    {:ok, claim} = claim(context)
    assert {:ok, _} = Work.fail(claim, :domain, %{"processing" => "projection_failed"})
    assert Repo.aggregate(Inventory.ReconciliationQuotaRetry, :count) == 0
    assert Work.get(context.scope, work.id).status == "quarantined"
    assert lane(context).pending_bytes == work.bytes

    assert Repo.get_by!(Renga.Quotas.Finding,
             organization_id: context.scope.organization_id,
             name: "resources"
           ).resolved_at
  end

  test "owner quota findings list tenant-scoped durable items in bounded acceptance order",
       context do
    set_resource_quota!(context, 0)

    works =
      for n <- 1..3 do
        {:ok, %{work: work}} = admit(context, host("quota-list-#{n}"))

        assert {:ok, {:error, _}} =
                 Renga.Inventory.ReconciliationWorker.run_once(
                   organization_id: context.scope.organization_id
                 )

        work
      end

    assert {[], 0} = Work.list_quota_deferred(context.scope)
    membership = Repo.get!(Accounts.OrganizationMembership, context.scope.membership_id)
    {:ok, _} = Accounts.update_organization_membership(membership, %{role: "owner"})
    assert {[first], 3} = Work.list_quota_deferred(context.scope, limit: 1)
    assert first.work_id == hd(works).id
    assert {[second], 3} = Work.list_quota_deferred(context.scope, limit: 1, page: 2)
    assert second.work_id == Enum.at(works, 1).id
    assert {[third], 3} = Work.list_quota_deferred(context.scope, limit: 2, page: 2)
    assert third.work_id == Enum.at(works, 2).id
    other = other_installation()
    membership = Repo.get!(Accounts.OrganizationMembership, other.scope.membership_id)
    {:ok, _} = Accounts.update_organization_membership(membership, %{role: "owner"})
    assert {[], 0} = Work.list_quota_deferred(other.scope)
    assert {[finding], 1} = Renga.Findings.list_findings(context.scope, domain: "quota")
    assert finding.details["quota_deferred"].total == 3

    assert Enum.map(finding.details["quota_deferred"].items, & &1.work_id) ==
             Enum.map(works, & &1.id)
  end

  defp set_resource_quota!(context, limit) do
    :ok =
      Renga.Limits.set(
        context.scope.organization,
        [resources: limit],
        Renga.DeploymentAudit.operator("durable-quota-test")
      )
  end

  # Exercise rediscovery without sleeping for the deployment's periodic interval.
  defp make_quota_due!(context, work) do
    context.scope
    |> Work.get(work.id)
    |> Ecto.Changeset.change(run_after: DateTime.add(Renga.Time.utc_now_ms(), -1))
    |> Repo.update!()
  end

  defp other_installation do
    fixture = installation()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.delete_all(
        from org in Accounts.Organization, where: org.id == ^fixture.scope.organization_id
      )

      Repo.delete!(fixture.scope.user)
      Sandbox.checkin(Repo)
    end)

    fixture
  end

  defp installation do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {key, _}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    installation_id = Ecto.UUID.generate()
    {:ok, {agent, _lease}} = Inventory.record_intake_agent_check_in(scope, key, installation_id)
    %{scope: scope, key: key, installation_id: installation_id, agent: agent}
  end

  defp host(id) do
    %{
      "observation_id" => id,
      "observed_at" => "2026-10-30T00:00:00.000Z",
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => %{"machine_id" => id},
          "attributes" => %{"hostname" => id},
          "interfaces" => []
        }
      ]
    }
  end

  defp admit(context, params, limits \\ @limits),
    do:
      Work.admit(
        context.scope,
        context.key,
        context.installation_id,
        context.agent.source_id,
        params,
        limits
      )

  defp lane(context), do: Repo.get!(ReconciliationLane, context.scope.organization_id)

  defp claim(context, opts \\ []),
    do: Work.claim_next([organization_id: context.scope.organization_id] ++ opts)

  defp concurrent(operation) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        operation.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp concurrent_admissions(context, first, second, limits) do
    Repo.query!("BEGIN")

    Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(context.scope.organization_id)
    ])

    parent = self()

    tasks =
      for params <- [first, second] do
        concurrent(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:admitting, backend})
          admit(context, params, limits)
        end)
      end

    try do
      backends =
        for _ <- tasks do
          assert_receive {:admitting, backend}, 1_000
          backend
        end

      for backend <- backends, do: await_lock!(backend)
    after
      Repo.query!("COMMIT")
    end

    Task.await_many(tasks, 5_000)
  end

  defp await_lock!(backend, attempts \\ 200) do
    [[waiting]] =
      Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [
        backend
      ]).rows

    cond do
      waiting ->
        :ok

      attempts == 0 ->
        flunk("admission did not wait on the actual organization row")

      true ->
        Process.sleep(5)
        await_lock!(backend, attempts - 1)
    end
  end

  defp await_expired!(context, attempts \\ 500) do
    [[expired]] =
      Repo.query!(
        "SELECT expires_at <= clock_timestamp() FROM reconciliation_lanes WHERE organization_id = $1",
        [Ecto.UUID.dump!(context.scope.organization_id)]
      ).rows

    cond do
      expired ->
        :ok

      attempts == 0 ->
        flunk("claim did not expire")

      true ->
        Process.sleep(5)
        await_expired!(context, attempts - 1)
    end
  end

  defp await_succeeded!(context, work_id, attempts \\ 500) do
    cond do
      Work.get(context.scope, work_id).status == "succeeded" ->
        :ok

      attempts == 0 ->
        flunk("supervised worker did not rediscover accepted work")

      true ->
        Process.sleep(10)
        await_succeeded!(context, work_id, attempts - 1)
    end
  end
end
