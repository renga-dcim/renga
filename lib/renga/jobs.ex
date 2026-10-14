defmodule Renga.Jobs do
  @moduledoc """
  Durable jobs that agents lease over HTTPS (RFD 9).

  A job asks one agent to run one capability. Its row in `jobs` is a
  projection of its append-only `job_events`, and this module is the only
  writer of either: every change to a job is made together with the event
  that records it, in one transaction, through `apply!/4`.

  Nothing here knows about a particular capability. Parameters, results,
  limits, and classes come from the `Renga.Jobs.Capability` module registered
  for the job's `name@version`, and the retry and risk classes are copied onto
  the row when the job is created so later transitions never depend on the
  module.

  Running a job is at least once. A lease can lapse after the agent acted but
  before its final report arrived, so what happens next follows the
  capability's retry class rather than pretending the job ran exactly once.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Inventory.Agent
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Job
  alias Renga.Jobs.JobEvent
  alias Renga.Jobs.Registry
  alias Renga.Jobs.Settings
  alias Renga.Repo

  @lease_seconds 60
  @default_deadline_seconds 3600
  @max_deadline_seconds 7 * 24 * 3600
  @default_max_attempts 3
  @max_failure_reason_length 255
  @max_event_payload_bytes 64 * 1024
  @terminal_report_reserve_bytes 1024
  @agent_report_types ~w(started progress output succeeded failed cancelled)
  @work_report_types ~w(started progress output)

  ## Reading

  @doc "Fetches a job in the scope's organization, or nil."
  def get_job(%Scope{organization_id: organization_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Job, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  @doc "Fetches a job in the scope's organization."
  def get_job!(%Scope{organization_id: organization_id}, id) do
    Repo.get_by!(Job, id: id, organization_id: organization_id)
  end

  @doc """
  Lists the organization's jobs, newest first. Filters by `:state`,
  `:agent_id`, and `:batch_id`, and returns at most `:limit` (default 50).
  """
  def list_jobs(%Scope{organization_id: organization_id}, opts \\ []) do
    Job
    |> where([job], job.organization_id == ^organization_id)
    |> filter_jobs(opts)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  defp filter_jobs(query, opts) do
    Enum.reduce(opts, query, fn
      {:state, state}, query -> where(query, [job], job.state == ^state)
      {:agent_id, agent_id}, query -> where(query, [job], job.agent_id == ^agent_id)
      {:batch_id, batch_id}, query -> where(query, [job], job.batch_id == ^batch_id)
      _other, query -> query
    end)
  end

  @doc "A job's history in the order it happened."
  def list_events(%Scope{organization_id: organization_id}, %Job{id: job_id}) do
    JobEvent
    |> where([event], event.organization_id == ^organization_id and event.job_id == ^job_id)
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
  end

  ## Requesting

  @doc """
  Requests a capability of one agent, as the scope's user.

  The organization must allow the capability, the user's role must permit its
  risk class, the agent must be active and advertise it, and the capability's
  own `authorize/3` hook may refuse further. Parameters are validated against
  the capability before anything is stored.

  Options:

    * `:idempotency_key` - a retried request with the same key returns the job
      it created instead of a second one; reusing the key for a different
      request is `{:error, :idempotency_conflict}`.
    * `:not_after` - the deadline for an agent to lease the job, at most seven
      days away (default one hour).
    * `:batch_id` - groups jobs that one request fanned out to many agents.
  """
  def create_job(%Scope{} = scope, agent_id, capability_key, parameters, opts \\ []) do
    with {:ok, capability} <- Registry.fetch(capability_key),
         {:ok, actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        authorize_request!(scope, capability)
        do_create!(scope.organization_id, actor, agent_id, capability, parameters, opts, scope)
      end)
    end
  end

  @doc """
  Requests a capability on the system's behalf, for scheduled work and
  workflow steps. There is no user role to check, but the organization and
  agent checks still apply.
  """
  def create_system_job(organization_id, agent_id, capability_key, parameters, opts \\ []) do
    with {:ok, capability} <- Registry.fetch(capability_key) do
      Repo.transaction(fn ->
        lock_active_organization!(organization_id)
        scope = %Scope{organization_id: organization_id}
        do_create!(organization_id, :system, agent_id, capability, parameters, opts, scope)
      end)
    end
  end

  defp requesting_user(%Scope{user: %{id: user_id}, membership_id: membership_id})
       when not is_nil(membership_id),
       do: {:ok, {:user, user_id}}

  defp requesting_user(_scope), do: {:error, :forbidden}

  # Owners and admins may request `observe` jobs. `operate` and `interactive`
  # jobs need grants RFDs 13 and 14 define, so nobody may request them yet.
  defp authorize_request!(%Scope{} = scope, capability) do
    case capability.risk_class() do
      :observe -> authorize_member!(scope, ["owner", "admin"])
      _operate_or_interactive -> Repo.rollback(:forbidden)
    end
  end

  defp do_create!(organization_id, actor, agent_id, capability, parameters, opts, scope) do
    key = Capability.key(capability)
    organization = Repo.get!(Organization, organization_id)
    now = Renga.Time.utc_now_ms()

    unless key in Settings.allowed_capabilities(organization),
      do: Repo.rollback(:capability_not_allowed)

    agent = fetch_requestable_agent!(organization_id, agent_id, key)
    parameters = cast_parameters!(capability, parameters)
    not_after = deadline!(opts, now)

    case capability.authorize(scope, agent, parameters) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # Serializes creation per organization so idempotency and the rate limit
    # see every concurrent request.
    lock_job_creation!(organization_id)

    case find_idempotent!(organization_id, opts[:idempotency_key]) do
      nil ->
        enforce_rate_limit!(organization_id, now)

        job =
          Repo.insert!(%Job{
            organization_id: organization_id,
            agent_id: agent.id,
            batch_id: opts[:batch_id],
            capability: capability.name(),
            capability_version: capability.version(),
            risk_class: Atom.to_string(capability.risk_class()),
            retry_class: Atom.to_string(capability.retry_class()),
            parameters: parameters,
            requested_by_type: if(actor == :system, do: "system", else: "user"),
            requested_by_user_id: actor_user_id(actor),
            idempotency_key: opts[:idempotency_key],
            state: "queued",
            max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
            not_after: not_after,
            output_limit_bytes: capability.output_limit_bytes(),
            timeout_ms: capability.timeout_ms()
          })

        apply!(job, %{}, [{"created", actor, %{"capability" => key}}], now)

      %Job{} = existing ->
        if same_request?(existing, agent.id, capability, parameters),
          do: existing,
          else: Repo.rollback(:idempotency_conflict)
    end
  end

  defp actor_user_id({:user, user_id}), do: user_id
  defp actor_user_id(_actor), do: nil

  defp fetch_requestable_agent!(organization_id, agent_id, key) do
    agent =
      case Ecto.UUID.cast(agent_id) do
        {:ok, agent_id} ->
          Agent
          |> where([agent], agent.organization_id == ^organization_id and agent.id == ^agent_id)
          |> lock("FOR SHARE")
          |> Repo.one()

        :error ->
          nil
      end

    cond do
      is_nil(agent) -> Repo.rollback(:agent_not_found)
      agent.status != "active" -> Repo.rollback(:agent_disabled)
      key not in agent.capabilities -> Repo.rollback(:capability_not_advertised)
      true -> agent
    end
  end

  defp cast_parameters!(capability, parameters) do
    parameters
    |> stringify()
    |> capability.parameters_changeset()
    |> Changeset.apply_action(:validate)
    |> case do
      {:ok, parameters} -> stringify(parameters)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp deadline!(opts, now) do
    case Keyword.get(opts, :not_after) do
      nil ->
        DateTime.add(now, @default_deadline_seconds)

      %DateTime{} = not_after ->
        not_after = Renga.Time.floor_to_millisecond(not_after)
        seconds = DateTime.diff(not_after, now)

        if seconds > 0 and seconds <= @max_deadline_seconds,
          do: not_after,
          else: Repo.rollback(:invalid_deadline)

      _other ->
        Repo.rollback(:invalid_deadline)
    end
  end

  defp lock_job_creation!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext('renga.jobs.create'), hashtext($1))", [
      organization_id
    ])
  end

  defp find_idempotent!(_organization_id, nil), do: nil

  defp find_idempotent!(organization_id, key) when is_binary(key) and key != "" do
    Repo.get_by(Job, organization_id: organization_id, idempotency_key: key)
  end

  defp find_idempotent!(_organization_id, _key), do: Repo.rollback(:invalid_idempotency_key)

  defp same_request?(%Job{} = job, agent_id, capability, parameters) do
    job.agent_id == agent_id and job.capability == capability.name() and
      job.capability_version == capability.version() and job.parameters == parameters
  end

  # Job creation is bounded per organization rather than per batch, so a large
  # fan-out spreads over time instead of arriving at once.
  defp enforce_rate_limit!(organization_id, now) do
    limit = creation_rate_per_minute()
    since = DateTime.add(now, -60)

    recent =
      Job
      |> where([job], job.organization_id == ^organization_id and job.inserted_at > ^since)
      |> limit(^limit)
      |> select([job], job.id)
      |> subquery()
      |> select([recent], count(recent.id))
      |> Repo.one!()

    if recent >= limit, do: Repo.rollback(:rate_limited)
  end

  defp creation_rate_per_minute do
    :renga
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:creation_rate_per_minute, 10_000)
  end

  ## Cancelling

  @doc """
  Cancels a job as an owner or admin. A queued job is cancelled at once; a
  leased or running one records the request, which the agent sees on its next
  report and acknowledges with a `cancelled` report.
  """
  def cancel_job(%Scope{} = scope, job_id) do
    with {:ok, actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        authorize_member!(scope, ["owner", "admin"])

        scope.organization_id
        |> lock_job!(job_id)
        |> cancel!(actor, Renga.Time.utc_now_ms())
      end)
    end
  end

  defp cancel!(%Job{state: "queued"} = job, actor, now),
    do: apply!(job, %{state: "cancelled", finished_at: now}, [{"cancelled", actor, %{}}], now)

  defp cancel!(%Job{cancel_requested_at: nil} = job, actor, now) do
    if job.state in Job.leased_states(),
      do: apply!(job, %{cancel_requested_at: now}, [{"cancel_requested", actor, %{}}], now),
      else: Repo.rollback(:not_cancellable)
  end

  # Already requested: asking again records nothing new.
  defp cancel!(%Job{} = job, _actor, _now) do
    if job.state in Job.leased_states(), do: job, else: Repo.rollback(:not_cancellable)
  end

  ## Leasing and reporting (agent side)

  @doc "The report types an agent may post on a job it holds."
  def report_types, do: @agent_report_types

  @doc """
  Leases up to `limit` queued jobs for `agent` among the capability keys the
  agent will run now, oldest first.

  Each leased job gets a fresh random lease token, returned once alongside the
  job and stored only as a hash, and a lease that lapses after #{@lease_seconds}
  seconds unless a report extends it. `SKIP LOCKED` lets concurrent lease
  requests share the queue without waiting on each other. A queued job whose
  capability the organization no longer allows fails here instead of running.

  ## Options

    * `:risk_classes` - lease only jobs of these risk classes. Callers that
      authenticate the agent with a shared organization credential pass
      `["observe"]` (RFD 9, "Trust boundary").
  """
  def lease_jobs(scope, agent, keys, limit, opts \\ [])

  def lease_jobs(%Scope{organization_id: organization_id}, %Agent{} = agent, keys, limit, opts)
      when is_list(keys) and is_integer(limit) and limit > 0 do
    if agent.organization_id != organization_id do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        organization = lock_active_organization!(organization_id)
        allowed = Settings.allowed_capabilities(organization)
        now = Renga.Time.utc_now_ms()

        organization_id
        |> leasable_jobs(agent, keys, limit, now)
        |> where_risk_class(Keyword.get(opts, :risk_classes))
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()
        |> Enum.flat_map(&lease_or_refuse!(&1, agent, allowed, now))
      end)
    end
  end

  defp leasable_jobs(organization_id, agent, keys, limit, now) do
    Job
    |> where([job], job.organization_id == ^organization_id and job.agent_id == ^agent.id)
    |> where([job], job.state == "queued" and job.not_after > ^now)
    |> where(
      [job],
      fragment(
        "(? || '@' || ?::text) = ANY(?)",
        job.capability,
        job.capability_version,
        type(^keys, {:array, :string})
      )
    )
    |> order_by([job], asc: job.inserted_at, asc: job.id)
    |> limit(^limit)
  end

  defp where_risk_class(query, nil), do: query

  defp where_risk_class(query, risk_classes) when is_list(risk_classes),
    do: where(query, [job], job.risk_class in ^risk_classes)

  defp lease_or_refuse!(%Job{} = job, agent, allowed, now) do
    if Job.capability_key(job) in allowed do
      [lease!(job, agent, now)]
    else
      refuse!(job, "capability_not_allowed", now)
      []
    end
  end

  defp lease!(%Job{} = job, %Agent{} = agent, now) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    job =
      apply!(
        job,
        %{
          state: "leased",
          attempts: job.attempts + 1,
          lease_token_hash: hash_token(token),
          leased_at: now,
          lease_expires_at: lease_expiry(now),
          started_at: nil
        },
        [{"leased", {:agent, agent.id}, %{}}],
        now
      )

    {job, token}
  end

  defp refuse!(%Job{} = job, reason, now) do
    apply!(
      job,
      %{state: "failed", failure_reason: reason, finished_at: now},
      [{"failed", :system, %{"reason" => reason}}],
      now
    )
  end

  @doc """
  Records an agent's report on a job it holds, proven by the lease token.

  `type` is one of #{Enum.map_join(@agent_report_types, ", ", &"`#{&1}`")}.
  Every accepted report extends the lease. The returned job's
  `cancel_requested_at` tells the agent whether to stop.

  `succeeded` payloads are `%{"result" => result}`, checked against the
  capability; `failed` payloads carry a `"reason"`; `cancelled` is accepted
  only after cancellation was requested. Agent-supplied payloads count toward
  the job's output limit.

  ## Options

    * `:sequence` - the agent's number for this report within the current
      attempt, a positive integer that grows with each report. A report whose
      sequence was already recorded by the same agent in the same attempt is
      a retry: it returns the job as it is now without recording anything,
      even after the job finished and the lease was released, so a lost
      response to a final report never turns into a second outcome. Reusing
      a sequence for a different report type is `:sequence_conflict`, and a
      new report numbered below one already recorded is `:stale_sequence`.
  """
  def report(scope, agent, job_id, token, type, payload, opts \\ [])

  def report(
        %Scope{organization_id: organization_id},
        %Agent{} = agent,
        job_id,
        token,
        type,
        payload,
        opts
      )
      when type in @agent_report_types and is_map(payload) do
    sequence = Keyword.get(opts, :sequence)

    if valid_report_sequence?(sequence) do
      Repo.transaction(fn ->
        organization_id
        |> lock_job!(job_id)
        |> report!(agent, token, type, payload, sequence)
      end)
    else
      {:error, :invalid_report}
    end
  end

  def report(_scope, _agent, _job_id, _token, _type, _payload, _opts),
    do: {:error, :invalid_report}

  defp report!(%Job{} = job, agent, token, type, payload, sequence) do
    case delivered_report(job, agent, sequence) do
      nil -> record_report!(job, agent, token, type, payload, sequence)
      %JobEvent{type: ^type} -> job
      %JobEvent{} -> Repo.rollback(:sequence_conflict)
    end
  end

  defp valid_report_sequence?(nil), do: true
  defp valid_report_sequence?(sequence), do: is_integer(sequence) and sequence > 0

  # The event an earlier delivery of this report produced, if any. Scoped to
  # the job's current attempt and the reporting agent, so a sequence from a
  # lease that was lost and re-leased never matches.
  defp delivered_report(_job, _agent, nil), do: nil

  defp delivered_report(%Job{} = job, %Agent{} = agent, sequence) do
    JobEvent
    |> where([event], event.job_id == ^job.id and event.attempt == ^job.attempts)
    |> where([event], event.actor_type == "agent" and event.actor_id == ^agent.id)
    |> where([event], event.report_sequence == ^sequence)
    |> Repo.one()
  end

  defp record_report!(%Job{} = job, %Agent{} = agent, token, type, payload, sequence) do
    now = Renga.Time.utc_now_ms()

    unless lease_held?(job, agent, token, now), do: Repo.rollback(:lease_not_held)
    if stale_sequence?(job, sequence), do: Repo.rollback(:stale_sequence)

    payload = stringify(payload)
    {changes, payload} = report_changes!(job, type, payload, now)
    payload_bytes = payload_bytes(payload)

    if payload_bytes > @max_event_payload_bytes,
      do: Repo.rollback(:output_limit_exceeded)

    output_bytes = job.output_bytes + payload_bytes

    if output_bytes > report_output_limit(job, type),
      do: Repo.rollback(:output_limit_exceeded)

    changes =
      changes
      |> Map.put(:output_bytes, output_bytes)
      |> Map.put_new(:lease_expires_at, lease_expiry(now))

    apply!(job, changes, [{type, {:agent, agent.id}, payload, sequence}], now)
  end

  defp stale_sequence?(_job, nil), do: false

  defp stale_sequence?(%Job{} = job, sequence) do
    JobEvent
    |> where([event], event.job_id == ^job.id and event.attempt == ^job.attempts)
    |> where([event], event.report_sequence >= ^sequence)
    |> Repo.exists?()
  end

  defp lease_held?(%Job{} = job, %Agent{} = agent, token, now) do
    job.state in Job.leased_states() and job.agent_id == agent.id and is_binary(token) and
      DateTime.compare(job.lease_expires_at, now) == :gt and
      Plug.Crypto.secure_compare(hash_token(token), job.lease_token_hash)
  end

  defp report_changes!(%Job{state: "leased"}, "started", payload, now),
    do: {%{state: "running", started_at: now}, payload}

  defp report_changes!(%Job{state: "running"}, type, payload, _now)
       when type in ~w(progress output),
       do: {%{}, payload}

  defp report_changes!(%Job{} = job, "succeeded", payload, now) do
    {:ok, capability} = Registry.fetch(Job.capability_key(job))

    result =
      payload
      |> Map.get("result", %{})
      |> case do
        %{} = result -> result
        _other -> Repo.rollback(:invalid_result)
      end
      |> capability.result_changeset()
      |> Changeset.apply_action(:validate)
      |> case do
        {:ok, result} -> stringify(result)
        {:error, changeset} -> Repo.rollback(changeset)
      end

    {finish(%{state: "succeeded", result: result}, now), %{"result" => result}}
  end

  defp report_changes!(%Job{}, "failed", payload, now) do
    case Map.get(payload, "reason") do
      reason when is_binary(reason) and reason != "" ->
        reason = String.slice(reason, 0, @max_failure_reason_length)
        {finish(%{state: "failed", failure_reason: reason}, now), %{"reason" => reason}}

      _missing ->
        Repo.rollback(:invalid_failure)
    end
  end

  defp report_changes!(%Job{cancel_requested_at: %DateTime{}}, "cancelled", _payload, now),
    do: {finish(%{state: "cancelled"}, now), %{}}

  defp report_changes!(%Job{}, _type, _payload, _now), do: Repo.rollback(:invalid_transition)

  defp finish(changes, now) do
    Map.merge(changes, %{
      finished_at: now,
      lease_token_hash: nil,
      leased_at: nil,
      lease_expires_at: nil
    })
  end

  defp lease_expiry(now), do: DateTime.add(now, @lease_seconds)

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  # Work reports leave room for a small terminal report, so exhausting output
  # cannot prevent the agent from recording a failure or cancellation.
  defp report_output_limit(%Job{} = job, type) when type in @work_report_types do
    reserve = min(@terminal_report_reserve_bytes, div(job.output_limit_bytes, 2))
    job.output_limit_bytes - reserve
  end

  defp report_output_limit(%Job{} = job, _terminal_type), do: job.output_limit_bytes

  # PostgreSQL's JSONB text representation is the database constraint's source
  # of truth. It differs from compact JSON at boundaries (for example, spaces
  # after separators), so measure it in PostgreSQL rather than approximating.
  defp payload_bytes(payload) do
    %{rows: [[bytes]]} =
      Repo.query!("SELECT octet_length($1::jsonb::text)", [payload])

    bytes
  end

  ## Sweeping

  @sweep_batch 500

  @doc """
  Moves jobs on whose time has run out, as the system: jobs whose lease
  lapsed, which are re-queued, expired, cancelled or marked `uncertain` by
  their retry class, and queued jobs past their deadline, which expire.

  Each job is handled in its own transaction under `SKIP LOCKED`, so the
  sweep is idempotent and safe to run on every node at once. Returns how many
  jobs each part moved.
  """
  def sweep(now \\ Renga.Time.utc_now_ms()) do
    lapsed =
      Job
      |> where([job], job.state in ^Job.leased_states() and job.lease_expires_at <= ^now)
      |> sweep_ids()
      |> Enum.count(&sweep_one(&1, now, :lease))

    expired =
      Job
      |> where([job], job.state == "queued" and job.not_after <= ^now)
      |> sweep_ids()
      |> Enum.count(&sweep_one(&1, now, :deadline))

    %{lapsed: lapsed, expired: expired}
  end

  defp sweep_ids(query) do
    query
    |> order_by([job], asc: job.id)
    |> limit(@sweep_batch)
    |> select([job], job.id)
    |> Repo.all()
  end

  defp sweep_one(job_id, now, kind) do
    {:ok, moved?} =
      Repo.transaction(fn ->
        Job
        |> where([job], job.id == ^job_id)
        |> sweep_condition(kind, now)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()
        |> move!(kind, now)
      end)

    moved?
  end

  defp move!(nil, _kind, _now), do: false

  defp move!(%Job{} = job, :lease, now) do
    lapse_lease(job, now)
    true
  end

  defp move!(%Job{} = job, :deadline, now) do
    expire!(job, now)
    true
  end

  defp sweep_condition(query, :lease, now),
    do: where(query, [job], job.state in ^Job.leased_states() and job.lease_expires_at <= ^now)

  defp sweep_condition(query, :deadline, now),
    do: where(query, [job], job.state == "queued" and job.not_after <= ^now)

  defp expire!(%Job{} = job, now) do
    apply!(
      job,
      %{state: "expired", finished_at: now},
      [{"expired", :system, %{"reason" => "not_leased_before_deadline"}}],
      now
    )
  end

  # What a lost lease means depends on how far the job got and its retry
  # class (RFD 9). Nothing ran before `started`, so any job may go back to
  # the queue; a started idempotent or convergent job may too, because
  # running it again is safe. A started imperative job may already have
  # acted, so it becomes `uncertain` for a person or reconciliation to
  # resolve and is never run again automatically. A requested cancellation
  # wins over a retry.
  defp lapse_lease(%Job{} = job, now) do
    started? = job.state == "running"
    imperative? = job.retry_class == "imperative"
    retry? = job.attempts < job.max_attempts and DateTime.compare(job.not_after, now) == :gt

    {next, final_events} =
      cond do
        started? and imperative? -> {"uncertain", [{"uncertain", :system, %{}}]}
        not is_nil(job.cancel_requested_at) -> {"cancelled", [{"cancelled", :system, %{}}]}
        retry? -> {"queued", []}
        true -> {"expired", [{"expired", :system, %{"reason" => "lease_lost"}}]}
      end

    changes =
      %{state: next, lease_token_hash: nil, leased_at: nil, lease_expires_at: nil}
      |> Map.merge(if next == "queued", do: %{started_at: nil}, else: %{})
      |> Map.merge(if next in Job.finished_states(), do: %{finished_at: now}, else: %{})

    apply!(job, changes, [{"lease_lost", :system, %{"next_state" => next}} | final_events], now)
  end

  ## Resolving uncertain jobs

  @max_note_length 1000

  @doc """
  Records what happened to an `uncertain` job, as an owner or admin who
  checked the target. `outcome` is `"succeeded"` or `"failed"`. Resolving
  never runs the job again; trying again means requesting a new job.
  """
  def resolve_job(%Scope{} = scope, job_id, outcome, note \\ nil)
      when outcome in ~w(succeeded failed) do
    with {:ok, actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        authorize_member!(scope, ["owner", "admin"])
        resolve!(scope.organization_id, job_id, actor, outcome, note_payload(note))
      end)
    end
  end

  @doc """
  Resolves an `uncertain` job from a later reconciliation, as the system,
  for example when fresh inventory shows the target reached the job's end
  state. `details` is recorded on the `resolved` event.
  """
  def reconcile_job(organization_id, job_id, outcome, details \\ %{})
      when outcome in ~w(succeeded failed) and is_map(details) do
    Repo.transaction(fn ->
      lock_active_organization!(organization_id)
      resolve!(organization_id, job_id, :system, outcome, stringify(details))
    end)
  end

  defp resolve!(organization_id, job_id, actor, outcome, payload) do
    job = lock_job!(organization_id, job_id)
    now = Renga.Time.utc_now_ms()

    unless job.state == "uncertain", do: Repo.rollback(:not_uncertain)

    payload = Map.put(payload, "outcome", outcome)

    if payload_bytes(payload) > @max_event_payload_bytes,
      do: Repo.rollback(:event_payload_too_large)

    changes =
      %{state: outcome, finished_at: now}
      |> Map.merge(if outcome == "failed", do: %{failure_reason: "resolved_failed"}, else: %{})

    apply!(job, changes, [{"resolved", actor, payload}], now)
  end

  defp note_payload(note) when is_binary(note) and note != "",
    do: %{"note" => String.slice(note, 0, @max_note_length)}

  defp note_payload(_note), do: %{}

  ## Retention and settings

  @purge_batch 1000

  @doc """
  Deletes finished jobs older than their organization's retention period
  (90 days unless an owner changed it), with their events. Jobs still open or
  `uncertain` are never purged. Deletes at most #{@purge_batch} jobs per
  call and returns how many it deleted.

  The event trigger allows these deletes only because the job row goes
  first; nothing else can remove history.
  """
  def purge_history(now \\ Renga.Time.utc_now_ms()) do
    %{num_rows: deleted} =
      Repo.query!(
        """
        DELETE FROM jobs
        WHERE id IN (
          SELECT job.id
          FROM jobs AS job
          JOIN organizations AS organization ON organization.id = job.organization_id
          WHERE job.finished_at IS NOT NULL
            AND job.finished_at < $1::timestamp - make_interval(days => GREATEST(1,
              CASE
                WHEN jsonb_typeof(organization.settings -> 'jobs' -> 'retention_days') = 'number'
                THEN floor((organization.settings -> 'jobs' ->> 'retention_days')::numeric)::integer
                ELSE $2::integer
              END))
          LIMIT $3
        )
        """,
        [DateTime.to_naive(now), Settings.default_retention_days(), @purge_batch]
      )

    deleted
  end

  @doc "The organization's job settings: allowed capabilities and retention."
  def get_settings(%Organization{} = organization) do
    %{
      allowed_capabilities: Settings.allowed_capabilities(organization),
      retention_days: Settings.retention_days(organization)
    }
  end

  @doc """
  Changes which capabilities may be targeted in the organization and how
  long job history is kept. Only an owner may. Allowing a capability does
  not let anyone request it: roles and, for `operate` and `interactive`
  capabilities, grants still apply.
  """
  def update_settings(%Scope{} = scope, attrs) do
    with {:ok, _actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        organization = lock_active_organization!(scope.organization_id, :update)
        authorize_membership!(scope, ["owner"])
        put_settings!(organization, attrs)
      end)
    end
  end

  defp put_settings!(%Organization{} = organization, attrs) do
    with {:ok, settings} <-
           organization |> Settings.changeset(attrs) |> Changeset.apply_action(:update),
         {:ok, organization} <-
           organization
           |> Changeset.change(settings: Settings.put(organization, settings))
           |> Repo.update() do
      get_settings(organization)
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  ## Writing

  # The only writer of jobs and their events: applies `changes` to a locked
  # job and appends `events` after its last sequence, in the caller's
  # transaction.
  defp apply!(%Job{} = job, changes, events, now) do
    attempt = Map.get(changes, :attempts, job.attempts)

    entries =
      events
      |> Enum.with_index(job.last_sequence + 1)
      |> Enum.map(fn {event, sequence} ->
        {type, actor, payload, report_sequence} = event_parts(event)
        {actor_type, actor_id} = actor_columns(actor)

        %{
          id: Ecto.UUID.generate(),
          organization_id: job.organization_id,
          job_id: job.id,
          sequence: sequence,
          attempt: attempt,
          type: type,
          actor_type: actor_type,
          actor_id: actor_id,
          payload: payload,
          report_sequence: report_sequence,
          inserted_at: now
        }
      end)

    job =
      job
      |> Changeset.change(Map.put(changes, :last_sequence, job.last_sequence + length(entries)))
      |> Repo.update!()

    {_count, nil} = Repo.insert_all(JobEvent, entries)
    job
  end

  defp event_parts({type, actor, payload}), do: {type, actor, payload, nil}
  defp event_parts({_type, _actor, _payload, _report_sequence} = event), do: event

  defp actor_columns({:user, user_id}), do: {"user", user_id}
  defp actor_columns({:agent, agent_id}), do: {"agent", agent_id}
  defp actor_columns(:system), do: {"system", nil}

  defp lock_job!(organization_id, job_id) do
    with {:ok, job_id} <- Ecto.UUID.cast(job_id),
         %Job{} = job <-
           Job
           |> where([job], job.organization_id == ^organization_id and job.id == ^job_id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      job
    else
      _missing -> Repo.rollback(:not_found)
    end
  end

  defp lock_active_organization!(organization_id, lock \\ :share) do
    query =
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> where([organization], organization.status == "active")

    query =
      case lock do
        :share -> lock(query, "FOR SHARE")
        :update -> lock(query, "FOR UPDATE")
      end

    query
    |> Repo.one()
    |> case do
      %Organization{} = organization -> organization
      nil -> Repo.rollback(:forbidden)
    end
  end

  # Rechecks the scope's membership inside the transaction so a stale browser
  # scope cannot act after its role was changed.
  defp authorize_member!(
         %Scope{
           membership_id: membership_id,
           organization_id: organization_id
         } = scope,
         roles
       )
       when not is_nil(membership_id) do
    lock_active_organization!(organization_id)
    authorize_membership!(scope, roles)
  end

  defp authorize_member!(%Scope{}, _roles), do: Repo.rollback(:forbidden)

  defp authorize_membership!(
         %Scope{
           membership_id: membership_id,
           user: %{id: user_id},
           organization_id: organization_id
         },
         roles
       )
       when not is_nil(membership_id) do
    member? =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.status == "active" and membership.role in ^roles)
      |> lock("FOR SHARE")
      |> Repo.exists?()

    unless member?, do: Repo.rollback(:forbidden)
  end

  defp authorize_membership!(%Scope{}, _roles), do: Repo.rollback(:forbidden)

  # Stores parameters, results, and payloads exactly as they read back from
  # JSONB, so comparisons (idempotency) and size accounting see one shape.
  defp stringify(value), do: value |> Renga.JSON.encode!() |> Renga.JSON.decode!()
end
