defmodule Renga.Inventory.ReconciliationWork do
  @moduledoc """
  Intake-authorized durable obligations, ordered and fenced per organization.

  Admission stores only a validated root payload and its ledger. Units cover
  root + declared resources + targets; bytes cover the root and its bounded
  derived payload expansion. The worker materializes and reconciles each report
  in one transaction. Resumable member processing is deliberately separate.

  Accepted evidence belongs to the server: revoking/deleting its intake key or
  agent does not revoke processing. Their recorded IDs are immutable provenance.
  Only admission checks the current key/installation/source under SHARE locks.
  Processing lock order is organization NO KEY UPDATE → organization advisory → human
  membership for explicit retry → source SHARE → lane UPDATE → work UPDATE →
  canonical/resource/projection locks. Source edits serialize at our SHARE lock;
  the host core takes a compatible SHARE on the same source snapshot.
  Scheduler selection is the narrow exception: jointly lock org/lane SKIP LOCKED,
  try the advisory lock, then take source SHARE and work UPDATE NOWAIT. No row
  lock acquired after that early lane lock may wait. A real savepoint recovers
  contention without changing work; only last_turn_at records a busy attempt.
  SQL alias order is not an org-before-lane acquisition guarantee.

  Claims and checkpoints grant no authority outside a fresh transaction. Every
  publication and post-rollback failure fences token, lane version, exact work,
  generation, checkpoint, status and fresh database expiry. Successful completion
  and exactly-once reservation debit commit together. Quarantine pins evidence
  and retains the full reservation. There is no renewal or abandonment API.
  All retained work, including succeeded work, pins its root evidence and first
  receipt until organization purge. Independent lane/work deletion is refused;
  bounded history cleanup is deliberately a later, separately reviewed slice.

  The 30s claim, 5s statement and 35s outer transaction budgets are development
  bounds, not capacity evidence or physical commit-before-expiry guarantees.
  PostgreSQL 17+ transaction_timeout and the client deadline bound the actual
  outer transaction; final expiry uses clock_timestamp() after DB effects.
  Operation callbacks must contain DB effects only, never external critical work.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ReconciliationAdmission
  alias Renga.Inventory.ReconciliationLane
  alias Renga.Inventory.Reconciler
  alias Renga.Inventory.Source
  alias Renga.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "reconciliation_work" do
    field :organization_id, Ecto.UUID
    field :observation_id, Ecto.UUID
    field :source_id, Ecto.UUID
    field :position, :integer
    field :units, :integer
    field :bytes, :integer
    field :status, :string, default: "pending"
    field :checkpoint, :integer, default: 0
    field :generation, :integer, default: 0
    field :origin, :string, default: "intake"
    field :original_key_id, Ecto.UUID
    field :installation_agent_id, Ecto.UUID
    field :installation_id, Ecto.UUID
    field :run_after, :utc_datetime_usec
    field :quarantine_kind, :string
    field :error, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Atomically accepts a validated root and reserves its ordered obligation.
  Requires an already registered installation and explicit authenticated key.
  A pre-existing synchronous observation without a ledger is not a replay.
  """
  def admit(scope, key, installation_id, source_id, params, limits)

  def admit(%Scope{} = scope, %IntakeApiKey{} = key, installation_id, source_id, params, limits) do
    validate_limits!(limits)

    transaction(fn ->
      lock_organization!(scope.organization_id)

      agent =
        Repo.get_by(Agent,
          organization_id: scope.organization_id,
          installation_id: installation_id
        )

      if is_nil(agent), do: Repo.rollback(:authority_unavailable)

      authority =
        require_authority!(scope.organization_id, key.id, agent.id, installation_id, source_id)

      if authority.key.token_hash != key.token_hash, do: Repo.rollback(:authority_unavailable)
      attrs = validated_attrs!(params, authority.source)
      lane = lock_lane!(scope.organization_id)

      case Inventory.accept_observation(
             scope,
             source_id,
             Map.put(attrs, :intake_api_key_id, key.id)
           ) do
        {:ok, observation, :created} ->
          work = reserve!(lane, observation, key.id, agent.id, installation_id, limits)
          %{receipt: receipt_value(work), work: work, disposition: :created}

        {:ok, observation, :duplicate} ->
          work =
            first_work(scope.organization_id, observation.id) ||
              Repo.rollback(:unsupported_existing_observation)

          %{receipt: receipt_value(work), work: work, disposition: :duplicate}

        {:error, :idempotency_conflict, _observation} ->
          Repo.rollback(:idempotency_conflict)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def admit(%Scope{}, _key, _installation_id, _source_id, _params, _limits),
    do: {:error, :unsupported_authority}

  @doc false
  def acceptance_transaction(%Scope{} = scope, operation) do
    transaction(fn ->
      lock_organization!(scope.organization_id)
      operation.()
    end)
  end

  @doc false
  # Registration, evidence, work and the lease share this caller-owned transaction.
  def accept_in_transaction!(scope, key, agent, source, attrs) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "acceptance requires a transaction")

    authority =
      require_authority!(
        scope.organization_id,
        key.id,
        agent.id,
        agent.installation_id,
        source.id
      )

    if authority.key.token_hash != key.token_hash, do: Repo.rollback(:intake_credential_changed)
    validated = validated_attrs!(attrs.payload, authority.source)
    attrs = Map.merge(attrs, validated) |> Map.put(:intake_api_key_id, key.id)

    case Inventory.accept_observation(scope, source.id, attrs) do
      {:ok, observation, :created} ->
        reserve!(
          lock_lane!(scope.organization_id),
          observation,
          key.id,
          agent.id,
          agent.installation_id,
          limits(scope.organization_id)
        )

        {observation, :created}

      {:ok, observation, :duplicate} ->
        first_work(scope.organization_id, observation.id) ||
          Repo.rollback(:unsupported_existing_observation)

        {observation, :duplicate}

      {:error, :idempotency_conflict, observation} ->
        Repo.rollback({:idempotency_conflict, observation})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def limits(organization_id) do
    values = Renga.Limits.get_all(organization_id)
    %{max_units: values.pending_work_units, max_bytes: values.pending_work_bytes}
  end

  def pending_units(organization_id), do: pending_usage(organization_id, :pending_units)
  def pending_bytes(organization_id), do: pending_usage(organization_id, :pending_bytes)

  defp pending_usage(organization_id, field) do
    Repo.one(
      from lane in ReconciliationLane,
        where: lane.organization_id == ^organization_id,
        select: field(lane, ^field)
    ) || 0
  end

  @doc "Immutable first acceptance and current disposition, without changing any work."
  def accepted(%Scope{} = scope, %Observation{} = observation) do
    first = first_work(scope.organization_id, observation.id)

    if first do
      %{observation: observation, receipt: receipt_value(first), work: latest_work(first)}
    end
  end

  @doc "The immutable first receipt, not a mutable processing-status response."
  def receipt(%Scope{organization_id: organization_id}, observation_id) do
    case first_work(organization_id, observation_id) do
      nil -> nil
      work -> receipt_value(work)
    end
  end

  @doc "Reads one tenant-scoped obligation without renewing or reviving it."
  def get(%Scope{organization_id: organization_id}, work_id),
    do: Repo.get_by(__MODULE__, organization_id: organization_id, id: work_id)

  @doc """
  Internal maintenance/operator entry point. Even immediate execution must
  reserve durable work and claim the organization head; it cannot jump a barrier.
  Machine callers are internal, not intake-key authentication substitutes.
  """
  def reconcile(%Scope{} = scope, observation, opts \\ []) do
    if Repo.in_transaction?(),
      do: raise(ArgumentError, "post-commit dispatch requires top-level reconciliation")

    prepared =
      transaction(fn ->
        lock_organization!(scope.organization_id)
        if scope.user, do: Authorization.authorize!(scope, "inventory.reconcile")
        Keyword.get(opts, :authorize, fn -> :ok end).()
        requested = Inventory.get_observation!(scope, observation.id)

        observation =
          if requested.parent_observation_id,
            do: Inventory.get_observation!(scope, requested.parent_observation_id),
            else: requested

        lock_source!(scope.organization_id, observation.source_id)
        first = first_work(scope.organization_id, observation.id)
        work = if first, do: latest_work(first)

        legacy_result =
          if is_nil(work),
            do: List.last(Inventory.list_observation_reconciliations(scope, observation.id))

        action =
          cond do
            (opts[:once] || is_nil(scope.user)) &&
                ((work && work.status in ["succeeded", "quarantined"]) ||
                   (legacy_result && legacy_result.status in ["succeeded", "failed"])) ->
              {:stored, Reconciler.stored_result(scope, observation)}

            is_nil(work) ->
              work =
                reserve!(
                  lock_lane!(scope.organization_id),
                  observation,
                  observation.intake_api_key_id,
                  nil,
                  nil,
                  limits(scope.organization_id),
                  "maintenance"
                )

              if legacy_result do
                audit!(
                  scope,
                  work,
                  "reconciliation_legacy_retry",
                  %{"attempt" => legacy_result.attempt, "status" => legacy_result.status},
                  %{"work_id" => work.id, "status" => "pending"}
                )
              end

              {:scheduled, work}

            opts[:once] || is_nil(scope.user) ->
              {:scheduled, work}

            true ->
              {:retry, work}
          end

        {requested, action}
      end)

    prepared =
      case prepared do
        {:ok, {requested, {:retry, work}}} ->
          retried =
            if work.status == "succeeded",
              do: terminal_retry(scope, work.id, work.generation, limits(scope.organization_id)),
              else: retry(scope, work.id, work.generation)

          case retried do
            {:ok, work} -> {:ok, {requested, {:scheduled, work}}}
            error -> error
          end

        result ->
          result
      end

    result =
      case prepared do
        {:ok, {_requested, {:stored, result}}} ->
          result

        {:ok, {_requested, {:scheduled, work}}} ->
          case Renga.Inventory.ReconciliationWorker.run_once(
                 organization_id: scope.organization_id,
                 work_id: work.id
               ) do
            {:ok, idle} when idle in [:idle, :busy] ->
              # Another bounded caller may have completed this exact obligation
              # while we waited for the slot. Reading it grants no retry authority.
              if get(scope, work.id).status in ["succeeded", "quarantined"],
                do:
                  Reconciler.stored_result(
                    scope,
                    Inventory.get_observation!(scope, work.observation_id)
                  ),
                else: {:error, :work_pending}

            {:ok, result} ->
              result

            error ->
              error
          end

        error ->
          error
      end

    result =
      case prepared do
        {:ok, {%Observation{parent_observation_id: parent_id} = requested, _action}}
        when not is_nil(parent_id) ->
          if match?({:ok, _, _}, result),
            do: Reconciler.stored_result(scope, requested),
            else: result

        _ ->
          result
      end

    Keyword.get(opts, :after_commit, fn result, _owner -> result end).(result, :durable)
  end

  @doc """
  Rediscover and claim one ready organization head without notifications.

  Readiness is tested AFTER choosing the earliest of all unresolved work, so a
  delayed or quarantined head blocks later work. Locked organizations are skipped
  rather than waited on. last_turn_at advances at claim, including turns that
  crash/fail afterward; it is persistent scheduling preference, not strict rounds.
  """
  def claim_next(opts \\ []) do
    transaction(fn ->
      case candidate(opts[:organization_id], opts[:work_id]) do
        nil -> :idle
        organization_id -> claim_locked!(organization_id, opts)
      end
    end)
  end

  @doc """
  Runs DB-only host work inside its own fenced outer transaction. A callback
  returns `{:progress, value}`, `{:complete, value}` or `{:error, reason}`.
  Scoped/derived work is deliberately not executable by this host adapter.
  Errors roll back without bookkeeping: a crash before `fail/4` leaves the same
  obligation discoverable after expiry. No public reconciler retry wrapper runs.
  """
  def execute(claim, operation, opts \\ []) when is_function(operation, 2) do
    transaction(
      fn ->
        {lane, work, source} = lock_turn!(claim)

        observation =
          Repo.get_by!(Observation,
            organization_id: work.organization_id,
            id: work.observation_id
          )

        if opts[:host_only], do: require_host!(observation, source)
        scope = Accounts.scope_for(Repo.get!(Organization, work.organization_id))

        case operation.(scope, observation) do
          {:progress, value} ->
            finish!(claim, lane, work, "pending", value)

          {:complete, value} ->
            finish!(claim, lane, work, "succeeded", value)

          {:quarantine, value} ->
            finish!(claim, lane, work, "quarantined", value)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      opts
    )
  end

  @doc "Runs one complete report, including expansion and required DB effects, under its fence."
  def execute_report(claim, opts \\ []) do
    execute(
      claim,
      fn scope, observation ->
        Inventory.materialize_observation_in_transaction!(scope, observation)

        case Reconciler.reconcile_in_transaction(scope, observation) do
          {:ok, _resources, _discovered?} = result -> {:complete, result}
          {:error, %Renga.Inventory.ObservationReconciliation{}} = result -> {:quarantine, result}
          {:error, reason} -> {:error, reason}
        end
      end,
      opts
    )
  end

  @doc "Exercises the existing atomic host core, with outcomes and debit in its fence."
  def execute_host(claim, opts \\ []) do
    execute(
      claim,
      fn scope, observation ->
        case Reconciler.reconcile_in_transaction(scope, observation) do
          {:ok, _resource, _discovered?} = result -> {:complete, result}
          {:error, reason} -> {:error, reason}
        end
      end,
      Keyword.put(opts, :host_only, true)
    )
  end

  @doc """
  Post-rollback bookkeeping, conditional on the SAME unexpired ownership and
  unadvanced checkpoint. `:backoff` retains pending work; `:domain` permanently
  quarantines it until explicit operator retry, retaining evidence and charge.
  """
  def fail(claim, kind, error, opts \\ []) when kind in [:backoff, :domain] and is_map(error) do
    transaction(
      fn ->
        {lane, work, _source} = lock_turn!(claim)

        {status, quarantine_kind} =
          if kind == :backoff, do: {"pending", nil}, else: {"quarantined", "domain"}

        changes = [
          status: status,
          quarantine_kind: quarantine_kind,
          error: error,
          run_after: DateTime.add(database_now(), Keyword.get(opts, :backoff_ms, 0), :millisecond)
        ]

        if opts[:record_attempt] do
          scope = Accounts.scope_for(Repo.get!(Organization, work.organization_id))
          observation = Repo.get!(Observation, work.observation_id)
          Reconciler.record_failure_in_transaction(scope, observation, error)
        end

        update_owned_work!(claim, changes)
        release_owned_lane!(claim, lane, 0, 0)
        Repo.get!(__MODULE__, work.id)
      end,
      opts
    )
  end

  @doc "Explicit retry of the named outstanding obligation: new generation, no new charge."
  def retry(%Scope{} = scope, work_id, generation) do
    human_transaction(scope, fn ->
      work = scoped_work!(scope.organization_id, work_id)
      lock_source!(work.organization_id, work.source_id)
      lane = lock_lane!(scope.organization_id)
      work = lock_work!(scope.organization_id, work_id)
      require_generation!(work, generation)
      if work.status == "succeeded", do: Repo.rollback(:terminal_work)

      audit!(
        scope,
        work,
        "reconciliation_retry",
        %{"generation" => generation, "status" => work.status},
        %{"generation" => generation + 1, "status" => "pending"}
      )

      invalidate_lane!(lane)

      change!(work,
        generation: generation + 1,
        status: "pending",
        run_after: database_now(),
        quarantine_kind: nil,
        error: %{}
      )
    end)
  end

  @doc "Admits a NEW obligation for the latest terminal work; the first receipt stays fixed."
  def terminal_retry(%Scope{} = scope, work_id, generation, limits) do
    validate_limits!(limits)

    human_transaction(scope, fn ->
      work = scoped_work!(scope.organization_id, work_id)

      lock_source!(work.organization_id, work.source_id)

      lane = lock_lane!(scope.organization_id)
      work = lock_work!(scope.organization_id, work_id)
      require_generation!(work, generation)
      if work.status != "succeeded", do: Repo.rollback(:not_terminal)
      if latest_work(work).id != work.id, do: Repo.rollback(:superseded)
      observation = Repo.get!(Observation, work.observation_id)

      next =
        reserve!(
          lane,
          observation,
          work.original_key_id,
          work.installation_agent_id,
          work.installation_id,
          limits,
          work.origin
        )

      audit!(scope, next, "reconciliation_terminal_retry", %{"work_id" => work.id}, %{
        "work_id" => next.id
      })

      next
    end)
  end

  defp transaction(operation, opts \\ []) do
    if Repo.in_transaction?(),
      do: raise(ArgumentError, "durable work requires a top-level transaction")

    statement_ms = budget!(opts, :statement_ms, 5_000)
    transaction_ms = budget!(opts, :transaction_ms, 35_000)

    Repo.transaction(
      fn ->
        Repo.query!("SELECT set_config('transaction_timeout', $1, true)", ["#{transaction_ms}ms"])
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{statement_ms}ms"])
        operation.()
      end,
      timeout: transaction_ms
    )
  end

  defp budget!(opts, key, maximum) do
    value = Keyword.get(opts, key, maximum)

    if not is_integer(value) or value <= 0 or value > maximum,
      do: raise(ArgumentError, "invalid #{key} development budget")

    value
  end

  defp validate_limits!(%{max_units: units, max_bytes: bytes})
       when is_integer(units) and units >= 0 and is_integer(bytes) and bytes >= 0, do: :ok

  defp validate_limits!(_limits),
    do: raise(ArgumentError, "explicit max_units and max_bytes are required")

  defp lock_organization!(organization_id) do
    Authorization.lock_active_organization!(organization_id, :no_key_update)
    Inventory.lock_organization!(organization_id)
  end

  defp human_transaction(%Scope{user: %{}} = scope, operation) do
    transaction(fn ->
      lock_organization!(scope.organization_id)
      Authorization.authorize!(scope, "inventory.reconcile")
      operation.()
    end)
  end

  defp human_transaction(%Scope{}, _operation), do: {:error, :forbidden}

  defp lock_lane!(organization_id) do
    Repo.insert!(%ReconciliationLane{organization_id: organization_id}, on_conflict: :nothing)

    Repo.one!(
      from lane in ReconciliationLane,
        where: lane.organization_id == ^organization_id,
        lock: "FOR UPDATE"
    )
  end

  defp scoped_work!(organization_id, work_id) do
    Repo.get_by(__MODULE__, organization_id: organization_id, id: work_id) ||
      Repo.rollback(:not_found)
  end

  defp lock_work!(organization_id, work_id, opts \\ []) do
    query =
      from work in __MODULE__,
        where: work.organization_id == ^organization_id and work.id == ^work_id

    query =
      if opts[:nowait], do: lock(query, "FOR UPDATE NOWAIT"), else: lock(query, "FOR UPDATE")

    Repo.one!(query)
  end

  defp require_generation!(%{generation: generation}, generation), do: :ok
  defp require_generation!(_work, _generation), do: Repo.rollback(:stale_work)

  defp require_authority!(organization_id, key_id, agent_id, installation_id, source_id) do
    ReconciliationAdmission.current(organization_id, key_id, agent_id, installation_id, source_id)
    |> require_current!()
  end

  defp require_current!({:ok, authority}), do: authority
  defp require_current!({:error, reason}), do: Repo.rollback(reason)

  defp lock_source!(organization_id, source_id, opts \\ []) do
    query =
      from source in Source,
        where: source.organization_id == ^organization_id and source.id == ^source_id

    query = if opts[:nowait], do: lock(query, "FOR SHARE NOWAIT"), else: lock(query, "FOR SHARE")
    Repo.one!(query)
  end

  defp validated_attrs!(params, source) do
    attrs =
      case AgentPayload.validate_observation(params, source) do
        {:ok, attrs} -> attrs
        {:error, errors} -> Repo.rollback({:invalid_payload, errors})
      end

    expected = if source.collector_id, do: {source.collector_id, source.kind}, else: nil
    if AgentPayload.collector(attrs.payload) != expected, do: Repo.rollback(:source_not_owned)
    attrs
  end

  defp reserve!(
         lane,
         observation,
         original_key_id,
         agent_id,
         installation_id,
         limits,
         origin \\ "intake"
       ) do
    units = reserved_units(observation.payload)
    bytes = reserved_bytes(observation.payload)

    if lane.pending_units + units > limits.max_units or
         lane.pending_bytes + bytes > limits.max_bytes,
       do: Repo.rollback(:capacity)

    now = database_now()

    work =
      Repo.insert!(%__MODULE__{
        organization_id: observation.organization_id,
        observation_id: observation.id,
        source_id: observation.source_id,
        position: lane.position + 1,
        units: units,
        bytes: bytes,
        origin: origin,
        original_key_id: original_key_id,
        installation_agent_id: agent_id,
        installation_id: installation_id,
        run_after: now,
        inserted_at: now
      })

    change!(lane,
      position: work.position,
      pending_units: lane.pending_units + units,
      pending_bytes: lane.pending_bytes + bytes
    )

    work
  end

  defp reserved_units(payload) do
    if AgentPayload.scoped_report?(payload),
      do:
        1 + length(Map.get(payload, "resources", [])) +
          length(AgentPayload.report_targets(payload)),
      else: 1
  end

  # Charge the actual bounded derived payload expansion before it can be written.
  # Stage 1 materializes it in the worker's single report transaction.
  defp reserved_bytes(payload) do
    root = byte_size(Jason.encode!(payload))

    if AgentPayload.scoped_report?(payload) do
      Enum.reduce(AgentPayload.derived_resource_payloads(payload), root, fn {_index, child},
                                                                            bytes ->
        bytes + byte_size(Jason.encode!(child))
      end)
    else
      root
    end
  end

  defp first_work(organization_id, observation_id) do
    Repo.one(
      from work in __MODULE__,
        where:
          work.organization_id == ^organization_id and work.observation_id == ^observation_id,
        order_by: work.position,
        limit: 1
    )
  end

  defp latest_work(work) do
    Repo.one!(
      from other in __MODULE__,
        where:
          other.organization_id == ^work.organization_id and
            other.observation_id == ^work.observation_id,
        order_by: [desc: other.position],
        limit: 1
    )
  end

  defp receipt_value(work),
    do: %{
      work_id: work.id,
      observation_id: work.observation_id,
      source_id: work.source_id,
      position: work.position,
      accepted_at: work.inserted_at
    }

  defp candidate(organization_id, work_id) do
    # Take the head over ALL outstanding states before applying readiness.
    head =
      from work in __MODULE__,
        where: work.organization_id == parent_as(:lane).organization_id,
        where: work.status != "succeeded",
        order_by: work.position,
        limit: 1

    query =
      from org in Organization,
        as: :organization,
        join: lane in ReconciliationLane,
        as: :lane,
        on: lane.organization_id == org.id,
        inner_lateral_join: work in subquery(head),
        on: true,
        where: org.status == "active" and work.status == "pending",
        where: work.run_after <= fragment("clock_timestamp()"),
        where: is_nil(lane.expires_at) or lane.expires_at <= fragment("clock_timestamp()"),
        order_by: [asc_nulls_first: lane.last_turn_at, asc: org.id],
        limit: 1,
        select: org.id,
        lock: "FOR UPDATE OF o0, r1 SKIP LOCKED"

    query = if organization_id, do: where(query, [org], org.id == ^organization_id), else: query
    query = if work_id, do: where(query, [org, lane, work], work.id == ^work_id), else: query
    Repo.one(query)
  end

  defp claim_locked!(organization_id, opts) do
    # A noncooperating advisory holder must not stall the scheduler either.
    [[locked?]] =
      Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [organization_id]).rows

    if locked? do
      claim_without_waiting!(organization_id, opts)
    else
      record_busy_attempt!(organization_id)
    end
  end

  defp claim_without_waiting!(organization_id, opts) do
    # Ecto nested transactions are not savepoints. The selecting transaction
    # keeps its org/lane locks when a NOWAIT source/work lock is rolled back.
    Repo.query!("SAVEPOINT reconciliation_claim")

    result =
      try do
        claim_available!(organization_id, opts)
      rescue
        error in Postgrex.Error ->
          if error.postgres.code == :lock_not_available do
            Repo.query!("ROLLBACK TO SAVEPOINT reconciliation_claim")
            record_busy_attempt!(organization_id)
          else
            reraise error, __STACKTRACE__
          end
      end

    Repo.query!("RELEASE SAVEPOINT reconciliation_claim")
    result
  end

  defp record_busy_attempt!(organization_id) do
    Repo.update_all(
      from(lane in ReconciliationLane, where: lane.organization_id == ^organization_id),
      set: [last_turn_at: database_now()]
    )

    :busy
  end

  defp head_work!(organization_id) do
    Repo.one!(
      from work in __MODULE__,
        where: work.organization_id == ^organization_id and work.status != "succeeded",
        order_by: work.position,
        limit: 1
    )
  end

  defp claim_available!(organization_id, opts) do
    head = head_work!(organization_id)
    lock_source!(organization_id, head.source_id, nowait: true)
    lane = Repo.get!(ReconciliationLane, organization_id)
    work = lock_work!(organization_id, head.id, nowait: true)
    now = database_now()

    if work.id != head_work!(organization_id).id or work.status != "pending" or
         DateTime.compare(work.run_after, now) == :gt or
         (lane.expires_at && DateTime.compare(lane.expires_at, now) == :gt),
       do: Repo.rollback(:head_changed)

    token = Ecto.UUID.generate()
    version = lane.version + 1

    change!(lane,
      token: token,
      work_id: work.id,
      version: version,
      expires_at: DateTime.add(now, budget!(opts, :claim_ms, 30_000), :millisecond),
      last_turn_at: now
    )

    %{
      organization_id: organization_id,
      work_id: work.id,
      token: token,
      lane_version: version,
      generation: work.generation,
      checkpoint: work.checkpoint,
      status: work.status
    }
  end

  defp lock_turn!(claim) do
    lock_organization!(claim.organization_id)
    work = scoped_work!(claim.organization_id, claim.work_id)
    source = lock_source!(work.organization_id, work.source_id)
    lane = lock_lane!(claim.organization_id)
    work = lock_work!(claim.organization_id, claim.work_id)
    ensure_owned!(claim, lane, work)
    {lane, work, source}
  end

  defp ensure_owned!(claim, lane, work) do
    if {lane.token, lane.version, lane.work_id, work.generation, work.checkpoint, work.status} !=
         {claim.token, claim.lane_version, claim.work_id, claim.generation, claim.checkpoint,
          claim.status} or
         work.status != "pending",
       do: Repo.rollback(:stale_claim)

    unless Repo.exists?(owned_lane(claim)), do: Repo.rollback(:expired_claim)
  end

  defp owned_lane(claim),
    do:
      from(lane in ReconciliationLane,
        where: lane.organization_id == ^claim.organization_id and lane.token == ^claim.token,
        where: lane.work_id == ^claim.work_id,
        where:
          lane.version == ^claim.lane_version and lane.expires_at > fragment("clock_timestamp()")
      )

  defp update_owned_work!(claim, attrs) do
    query =
      from work in __MODULE__,
        where: work.organization_id == ^claim.organization_id and work.id == ^claim.work_id,
        where: work.generation == ^claim.generation and work.checkpoint == ^claim.checkpoint,
        where: work.status == ^claim.status and work.status == "pending"

    case Repo.update_all(query, set: attrs) do
      {1, _} -> :ok
      _ -> Repo.rollback(:stale_claim)
    end
  end

  defp release_owned_lane!(claim, lane, units, bytes) do
    # The final fresh clock check is under the held lane lock, AFTER effects and
    # work updates; a failed check rolls all of them back, including the debit.
    case Repo.update_all(owned_lane(claim),
           set: [
             token: nil,
             work_id: nil,
             expires_at: nil,
             version: lane.version + 1,
             pending_units: lane.pending_units - units,
             pending_bytes: lane.pending_bytes - bytes
           ]
         ) do
      {1, _} -> :ok
      _ -> Repo.rollback(:expired_claim)
    end
  end

  defp finish!(claim, lane, work, status, value) do
    update_owned_work!(claim,
      status: status,
      quarantine_kind: if(status == "quarantined", do: "domain"),
      checkpoint: work.checkpoint + 1,
      error: %{}
    )

    {units, bytes} = if status == "succeeded", do: {work.units, work.bytes}, else: {0, 0}
    release_owned_lane!(claim, lane, units, bytes)
    value
  end

  defp require_host!(observation, source) do
    if observation.parent_observation_id || AgentPayload.scoped_report?(observation.payload) ||
         source.kind != "host_agent",
       do: Repo.rollback(:unsupported_execution)
  end

  defp invalidate_lane!(lane),
    do: change!(lane, token: nil, work_id: nil, expires_at: nil, version: lane.version + 1)

  defp change!(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp audit!(scope, work, field, old_value, new_value) do
    {:ok, _} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: field,
        source_id: work.source_id,
        observation_id: work.observation_id,
        old_value: old_value,
        new_value: new_value,
        metadata: %{"work_id" => work.id, "generation" => work.generation}
      })
  end

  defp database_now, do: Repo.query!("SELECT clock_timestamp()").rows |> hd() |> hd()
end
