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
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.Agent
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Changes
  alias Renga.Jobs.Job
  alias Renga.Jobs.JobEvent
  alias Renga.Jobs.Registry
  alias Renga.Jobs.Settings
  alias Renga.Jobs.TargetBindings
  alias Renga.Repo

  @lease_seconds 60
  @default_deadline_seconds 3600
  @max_deadline_seconds 7 * 24 * 3600
  @default_max_attempts 3
  @max_failure_reason_length 255
  @max_event_payload_bytes 64 * 1024
  @terminal_report_reserve_bytes 1024
  @max_report_sequence 2_147_483_647
  @agent_report_types ~w(started progress output succeeded failed cancelled)
  @work_report_types ~w(started progress output)

  ## Reading
  #
  # Every read for people withholds the payloads of jobs whose capability
  # has `sensitive_output?/0` from readers who do not hold its permissions
  # now (RFD 12): parameters, the result, an agent's failure reason, and the
  # agent's reports. What the job is, where it ran, who asked, and how it
  # stands stay visible. Having requested the job grants nothing.

  @doc """
  Fetches a job in the scope's organization, or nil, with its payload
  withheld unless the scope may read it. `:preload` loads associations,
  such as `[:resource, :agent, :requested_by_user]`.
  """
  def get_job(%Scope{organization_id: organization_id} = scope, id, opts \\ []) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Job
        |> Repo.get_by(id: id, organization_id: organization_id)
        |> Repo.preload(Keyword.get(opts, :preload, []))
        |> withhold_payload(readable_payloads(scope))

      :error ->
        nil
    end
  end

  @doc "Fetches a job in the scope's organization, payload withheld as in `get_job/3`."
  def get_job!(%Scope{organization_id: organization_id} = scope, id) do
    Job
    |> Repo.get_by!(id: id, organization_id: organization_id)
    |> withhold_payload(readable_payloads(scope))
  end

  @doc """
  The `name@version` keys whose job payloads the scope may read now:
  capabilities without sensitive output, and those whose
  `required_permissions/0` the scope currently holds.
  """
  def readable_payloads(%Scope{} = scope) do
    sensitive = Enum.filter(Registry.all(), & &1.sensitive_output?())

    held =
      Authorization.held_now(
        scope,
        sensitive |> Enum.flat_map(& &1.required_permissions()) |> Enum.uniq()
      )

    for module <- Registry.all(),
        not module.sensitive_output?() or module.required_permissions() -- held == [],
        into: MapSet.new(),
        do: Capability.key(module)
  end

  @doc "The permissions reading `job`'s payload needs, for saying why it is withheld."
  def payload_permissions(%Job{} = job) do
    case Registry.fetch(Job.capability_key(job)) do
      {:ok, capability} -> capability.required_permissions()
      {:error, _unknown} -> []
    end
  end

  # Failure reasons Renga itself records; the agent's own reasons are payload.
  @system_failure_reasons ~w(capability_not_allowed binding_changed resolved_failed)

  defp withhold_payload(nil, _readable), do: nil

  defp withhold_payload(%Job{} = job, readable) do
    if MapSet.member?(readable, Job.capability_key(job)) do
      job
    else
      %{
        job
        | parameters: nil,
          result: nil,
          failure_reason:
            if(job.failure_reason in @system_failure_reasons, do: job.failure_reason),
          payload_hidden: true
      }
    end
  end

  @doc """
  Lists the organization's jobs, newest first, with their resource, agent,
  and requesting user. Filters by `:state`, `:group` (see `state_groups/0`),
  `:agent_id`, `:resource_id`, `:batch_id`, and `:capability`. Pass the oldest
  job already shown as `:before` to read the next keyset page. Returns at most
  `:limit` jobs (default 50).
  """
  def list_jobs(%Scope{organization_id: organization_id} = scope, opts \\ []) do
    Job
    |> where([job], job.organization_id == ^organization_id)
    |> filter_jobs(opts)
    |> jobs_before(Keyword.get(opts, :before))
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload([:resource, :agent, :requested_by_user])
    |> Repo.all()
    |> withhold_payloads(scope)
  end

  defp withhold_payloads([], _scope), do: []

  defp withhold_payloads(jobs, scope) do
    readable = readable_payloads(scope)
    Enum.map(jobs, &withhold_payload(&1, readable))
  end

  defp jobs_before(query, nil), do: query

  defp jobs_before(query, %Job{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [job],
      job.inserted_at < ^inserted_at or (job.inserted_at == ^inserted_at and job.id < ^id)
    )
  end

  @doc """
  How people sort jobs: `open` ones are still waiting or running,
  `needs_review` ones are `uncertain` until a person resolves them, and
  `finished` ones ended.
  """
  def state_groups do
    %{
      "open" => Job.open_states(),
      "needs_review" => ["uncertain"],
      "finished" => Job.finished_states()
    }
  end

  @doc "Counts the organization's jobs in each of `state_groups/0`."
  def count_jobs_by_group(%Scope{organization_id: organization_id}) do
    counts =
      Job
      |> where([job], job.organization_id == ^organization_id)
      |> group_by([job], job.state)
      |> select([job], {job.state, count(job.id)})
      |> Repo.all()
      |> Map.new()

    Map.new(state_groups(), fn {group, states} ->
      {group, states |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()}
    end)
  end

  defp filter_jobs(query, opts) do
    Enum.reduce(opts, query, fn
      {:state, state}, query ->
        where(query, [job], job.state == ^state)

      {:group, group}, query ->
        where(query, [job], job.state in ^Map.fetch!(state_groups(), group))

      {:agent_id, agent_id}, query ->
        where(query, [job], job.agent_id == ^agent_id)

      {:resource_id, id}, query ->
        where(query, [job], job.resource_id == ^id)

      {:batch_id, batch_id}, query ->
        where(query, [job], job.batch_id == ^batch_id)

      {:capability, {name, version}}, query ->
        where(query, [job], job.capability == ^name and job.capability_version == ^version)

      _other, query ->
        query
    end)
  end

  @doc """
  The newest inventory collection requested from `resource`, with its agent,
  or nil. Other resource-targeted capabilities do not replace the collection
  state shown on the resource page.
  """
  def latest_resource_collection(%Scope{} = scope, resource_id) do
    scope
    |> list_jobs(
      resource_id: resource_id,
      capability: {"inventory.collect", 1},
      limit: 1
    )
    |> List.first()
  end

  @doc "What people call the job's capability, such as \"Collect inventory\"."
  def title(%Job{} = job) do
    case Registry.fetch(Job.capability_key(job)) do
      {:ok, capability} -> capability.title()
      {:error, _unknown} -> Capability.default_title(job.capability)
    end
  end

  @doc "The job as the subject of an activity sentence, such as \"Inventory collection\"."
  def noun(%Job{} = job) do
    case Registry.fetch(Job.capability_key(job)) do
      {:ok, capability} -> capability.noun()
      {:error, _unknown} -> "#{title(job)} job"
    end
  end

  @doc """
  A job's history in the order it happened. The agent's reports keep their
  type and time but lose their payload when the scope may not read the
  job's payload; Renga's and people's events are kept whole.
  """
  def list_events(%Scope{organization_id: organization_id} = scope, %Job{id: job_id}) do
    events =
      JobEvent
      |> where([event], event.organization_id == ^organization_id and event.job_id == ^job_id)
      |> order_by([event], asc: event.sequence)
      |> Repo.all()

    readable? =
      case events do
        [] ->
          true

        _events ->
          key =
            Job
            |> where([job], job.organization_id == ^organization_id and job.id == ^job_id)
            |> select(
              [job],
              fragment("? || '@' || ?::text", job.capability, job.capability_version)
            )
            |> Repo.one()

          MapSet.member?(readable_payloads(scope), key)
      end

    if readable?,
      do: events,
      else: Enum.map(events, &withhold_event_payload/1)
  end

  defp withhold_event_payload(%JobEvent{actor_type: "agent"} = event),
    do: %{event | payload: %{}, payload_hidden: true}

  defp withhold_event_payload(%JobEvent{} = event), do: event

  @doc """
  Names for the people and agents behind `events`, keyed by actor id: a
  person's email or an agent's name. System events have no actor id.
  """
  def event_actor_names(%Scope{organization_id: organization_id}, events) do
    ids = fn type ->
      for %JobEvent{actor_type: ^type, actor_id: id} <- events, uniq: true, do: id
    end

    users =
      Renga.Accounts.User
      |> where([user], user.id in ^ids.("user"))
      |> select([user], {user.id, user.email})
      |> Repo.all()

    agents =
      Agent
      |> where([agent], agent.organization_id == ^organization_id and agent.id in ^ids.("agent"))
      |> select([agent], {agent.id, agent.name})
      |> Repo.all()

    Map.new(users ++ agents)
  end

  ## Requesting

  @doc """
  Requests a capability of one agent, as the scope's user.

  The organization must allow the capability, the user must hold its
  `required_permissions/0` (and only `observe` jobs may be requested yet), the agent must be active and advertise it, and the capability's
  own `authorize/3` hook may refuse further. Parameters are validated against
  the capability before anything is stored.

  Options:

    * `:idempotency_key` - a retried request with the same key returns the job
      it created instead of a second one; reusing the key for a different
      request is `{:error, :idempotency_conflict}`.
    * `:not_after` - the deadline for an agent to lease the job, at most seven
      days away (default one hour).
    * `:batch_id` - groups jobs that one request fanned out to many agents.
    * `:resource_id` - the resource the job was requested from. The agent
      must report on it (one of the resource's identifier claims comes from
      the agent's source); the job's request and outcome then appear in the
      resource's activity.
  """
  def create_job(%Scope{} = scope, agent_id, capability_key, parameters, opts \\ []) do
    with {:ok, capability} <- Registry.fetch(capability_key),
         {:ok, actor} <- requesting_user(scope) do
      create_announced(scope.organization_id, fn ->
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
      create_announced(organization_id, fn ->
        lock_active_organization!(organization_id)
        scope = %Scope{organization_id: organization_id}
        do_create!(organization_id, :system, agent_id, capability, parameters, opts, scope)
      end)
    end
  end

  # Creates in one transaction and announces the change, and the queued job
  # to its agent, only once it commits.
  defp create_announced(organization_id, create) do
    Changes.after_commit(fn ->
      create
      |> Repo.transaction()
      |> Changes.broadcast(organization_id)
    end)
  end

  defp requesting_user(%Scope{user: %{id: user_id}, membership_id: membership_id})
       when not is_nil(membership_id),
       do: {:ok, {:user, user_id}}

  defp requesting_user(_scope), do: {:error, :forbidden}

  # An `observe` job needs its capability's permissions: `jobs.request`, or
  # the explicit query permissions for a query (RFD 12). `operate` and
  # `interactive` jobs need grants RFDs 13 and 14 define, so nobody may
  # request them yet.
  defp authorize_request!(%Scope{} = scope, capability) do
    case capability.risk_class() do
      :observe -> authorize_all!(scope, capability.required_permissions())
      _operate_or_interactive -> Repo.rollback(:forbidden)
    end
  end

  # Cancelling or resolving a job needs what requesting it needed. A job's
  # capability never changes, so it is read before the job is locked, which
  # keeps the authorization locks first.
  defp authorize_for_job!(%Scope{} = scope, job_id) do
    permissions =
      with {:ok, job_id} <- Ecto.UUID.cast(job_id),
           %Job{} = job <-
             Repo.get_by(Job, id: job_id, organization_id: scope.organization_id),
           {:ok, capability} <- Registry.fetch(Job.capability_key(job)) do
        capability.required_permissions()
      else
        _missing_or_unregistered -> ["jobs.request"]
      end

    authorize_all!(scope, permissions)
  end

  defp authorize_all!(%Scope{} = scope, permissions),
    do: Enum.each(permissions, &authorize_member!(scope, &1))

  defp authorize_capability!(capability, scope, agent, parameters) do
    case capability.authorize(scope, agent, parameters) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A privileged job runs only where its resource is bound (RFD 13), never
  # wherever inventory currently reports the resource.
  defp capture_binding!(organization_id, agent, resource_id, capability) do
    if capability.risk_class() != :observe,
      do: TargetBindings.capture!(organization_id, agent, resource_id)
  end

  defp do_create!(organization_id, actor, agent_id, capability, parameters, opts, scope) do
    key = Capability.key(capability)
    organization = Repo.get!(Organization, organization_id)
    now = Renga.Time.utc_now_ms()

    unless key in Settings.allowed_capabilities(organization),
      do: Repo.rollback(:capability_not_allowed)

    agent = fetch_requestable_agent!(organization_id, agent_id, key)
    resource_id = fetch_reported_resource_id!(organization_id, agent, opts[:resource_id])
    parameters = cast_parameters!(capability, parameters)
    not_after = deadline!(opts, now)

    authorize_capability!(capability, scope, agent, parameters)
    binding = capture_binding!(organization_id, agent, resource_id, capability)

    # Serializes creation per organization so idempotency and the rate limit
    # see every concurrent request.
    lock_job_creation!(organization_id)

    case find_idempotent!(organization_id, opts[:idempotency_key]) do
      nil ->
        ensure_single_open_resource_collection!(organization_id, resource_id, capability)
        enforce_rate_limit!(organization_id, now)

        job =
          Repo.insert!(%Job{
            organization_id: organization_id,
            agent_id: agent.id,
            batch_id: opts[:batch_id],
            resource_id: resource_id,
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
            timeout_ms: capability.timeout_ms(),
            target_binding_id: binding && binding.id,
            target_binding_version: binding && binding.version
          })

        apply!(job, %{}, [{"created", actor, %{"capability" => key}}], now)

      %Job{} = existing ->
        if same_request?(existing, agent.id, resource_id, capability, parameters),
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

  # A job names a resource only when the agent reports on it, so a person
  # cannot attach a job, and its activity, to an unrelated resource.
  defp fetch_reported_resource_id!(_organization_id, _agent, nil), do: nil

  defp fetch_reported_resource_id!(organization_id, %Agent{} = agent, resource_id) do
    with {:ok, resource_id} <- Ecto.UUID.cast(resource_id),
         true <-
           Resource
           |> where([r], r.organization_id == ^organization_id and r.id == ^resource_id)
           |> lock("FOR SHARE")
           |> Repo.exists?() do
      if agent_reports_on?(organization_id, agent, resource_id),
        do: resource_id,
        else: Repo.rollback(:agent_not_for_resource)
    else
      _missing -> Repo.rollback(:resource_not_found)
    end
  end

  defp agent_reports_on?(_organization_id, %Agent{source_id: nil}, _resource_id), do: false

  defp agent_reports_on?(organization_id, %Agent{source_id: source_id}, resource_id) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id)
    |> where([claim], claim.resource_id == ^resource_id and claim.source_id == ^source_id)
    |> Repo.exists?()
  end

  @doc """
  The agents that report on a resource: those whose source made one of its
  identifier claims, most recently contacted first. Jobs requested from the
  resource go to one of these.
  """
  def list_resource_agents(%Scope{organization_id: organization_id}, resource_id) do
    sources =
      ResourceIdentifierClaim
      |> where([claim], claim.organization_id == ^organization_id)
      |> where([claim], claim.resource_id == ^resource_id)
      |> select([claim], claim.source_id)
      |> distinct(true)

    Agent
    |> where([agent], agent.organization_id == ^organization_id)
    |> where([agent], agent.source_id in subquery(sources))
    |> order_by([agent], desc_nulls_last: agent.last_contacted_at, asc: agent.id)
    |> Repo.all()
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

  defp same_request?(%Job{} = job, agent_id, resource_id, capability, parameters) do
    job.agent_id == agent_id and job.resource_id == resource_id and
      job.capability == capability.name() and
      job.capability_version == capability.version() and job.parameters == parameters
  end

  defp ensure_single_open_resource_collection!(_organization_id, nil, _capability), do: :ok

  defp ensure_single_open_resource_collection!(organization_id, resource_id, capability) do
    if Capability.key(capability) == "inventory.collect@1" do
      open? =
        Job
        |> where([job], job.organization_id == ^organization_id)
        |> where([job], job.resource_id == ^resource_id)
        |> where([job], job.capability == "inventory.collect" and job.capability_version == 1)
        |> where([job], job.state in ^Job.open_states())
        |> Repo.exists?()

      if open?, do: Repo.rollback(:resource_collection_open)
    end
  end

  # Job creation is bounded per organization rather than per batch, so a large
  # fan-out spreads over time instead of arriving at once.
  defp enforce_rate_limit!(organization_id, now) do
    limit = Renga.Limits.get(organization_id, :job_creation_rate)
    if recent_creations(organization_id, now, limit) >= limit, do: Repo.rollback(:rate_limited)
  end

  @doc """
  How many jobs the organization created in the minute before `now`, the
  usage its job creation limit (RFD 21) is measured against. Counting stops
  at `cap`, since the limit only needs to know whether it is reached.
  """
  def recent_creations(organization_id, now \\ Renga.Time.utc_now_ms(), cap \\ nil) do
    since = DateTime.add(now, -60)

    Job
    |> where([job], job.organization_id == ^organization_id and job.inserted_at > ^since)
    |> then(fn query -> if cap, do: limit(query, ^cap), else: query end)
    |> select([job], job.id)
    |> subquery()
    |> select([recent], count(recent.id))
    |> Repo.one!()
  end

  ## Cancelling

  @doc """
  Cancels a job; needs the permissions requesting it needs. A queued job is cancelled at once; a
  leased or running one records the request, which the agent sees on its next
  report and acknowledges with a `cancelled` report.
  """
  def cancel_job(%Scope{} = scope, job_id) do
    with {:ok, actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        authorize_for_job!(scope, job_id)

        scope.organization_id
        |> lock_job!(job_id)
        |> cancel!(actor, Renga.Time.utc_now_ms())
      end)
      |> Changes.broadcast(scope.organization_id)
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

  @doc "The largest report sequence representable by the database column."
  def max_report_sequence, do: @max_report_sequence

  @doc """
  Whether `agent` has queued jobs it could lease now. Check-in responses carry
  this as `jobs_waiting`, so an agent leases promptly instead of waiting for
  its next lease attempt.
  """
  def jobs_waiting?(%Scope{organization_id: organization_id}, %Agent{} = agent) do
    now = Renga.Time.utc_now_ms()

    Job
    |> where([job], job.organization_id == ^organization_id and job.agent_id == ^agent.id)
    |> where([job], job.state == "queued" and job.not_after > ^now)
    |> Repo.exists?()
  end

  @doc """
  Leases up to `limit` queued jobs for `agent` among the capability keys the
  agent will run now, oldest first.

  Each leased job gets a fresh random lease token, returned once alongside the
  job and stored only as a hash, and a lease that lapses after #{@lease_seconds}
  seconds unless a report extends it. `SKIP LOCKED` lets concurrent lease
  requests share the queue without waiting on each other. A queued job whose
  capability the organization no longer allows fails here instead of running.

  Only `observe` jobs lease here. `operate` and `interactive` jobs need a
  request signed with the installation's approved key (RFD 13), through
  `Renga.Jobs.SignedLeases`.
  """
  def lease_jobs(%Scope{organization_id: organization_id}, %Agent{} = agent, keys, limit)
      when is_list(keys) and is_integer(limit) and limit > 0 do
    if agent.organization_id != organization_id do
      {:error, :forbidden}
    else
      result =
        Repo.transaction(fn ->
          organization = lock_active_organization!(organization_id)
          allowed = Settings.allowed_capabilities(organization)
          now = Renga.Time.utc_now_ms()

          jobs =
            organization_id
            |> leasable_jobs(agent, keys, limit, now)
            |> where([job], job.risk_class == "observe")
            |> lock("FOR UPDATE SKIP LOCKED")
            |> Repo.all()

          {Enum.flat_map(jobs, &lease_or_refuse!(&1, agent, allowed, now)), jobs != []}
        end)

      broadcast_lease_change(result, organization_id)
    end
  end

  # An empty response usually changed nothing, but can also mean every queued
  # job was refused because its capability was withdrawn.
  defp broadcast_lease_change({:ok, {leased, false}}, _organization_id), do: {:ok, leased}

  defp broadcast_lease_change({:ok, {leased, true}}, organization_id),
    do: Changes.broadcast({:ok, leased}, organization_id)

  defp broadcast_lease_change(result, _organization_id), do: result

  @doc false
  def leasable_jobs(organization_id, agent, keys, limit, now) do
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

  defp lease_or_refuse!(%Job{} = job, agent, allowed, now) do
    if Job.capability_key(job) in allowed do
      [lease!(job, agent, now)]
    else
      refuse!(job, "capability_not_allowed", now)
      []
    end
  end

  defp lease!(%Job{} = job, %Agent{} = agent, now),
    do: lease_with_token!(job, agent, new_token(), now)

  @doc false
  def new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # Signed leases (RFD 13) lease with the token the agent signed over.
  @doc false
  def lease_with_token!(%Job{} = job, %Agent{} = agent, token, now) do
    job =
      apply!(
        job,
        %{
          state: "leased",
          attempts: job.attempts + 1,
          lease_token_hash: hash_token(token),
          report_token_hash: hash_token(token),
          leased_at: now,
          lease_expires_at: lease_expiry(now),
          started_at: nil
        },
        [{"leased", {:agent, agent.id}, %{}}],
        now
      )

    {job, token}
  end

  @doc """
  Fails the queued privileged jobs requested under a binding that just
  ended, so none of them runs on another installation (RFD 13).
  """
  def fail_queued_for_binding!(organization_id, binding_id, reason, now) do
    Job
    |> where([job], job.organization_id == ^organization_id)
    |> where([job], job.target_binding_id == ^binding_id and job.state == "queued")
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(&refuse!(&1, reason, now))
  end

  @doc false
  def refuse!(%Job{} = job, reason, now) do
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
      |> Changes.broadcast(organization_id)
    else
      {:error, :invalid_report}
    end
  end

  def report(_scope, _agent, _job_id, _token, _type, _payload, _opts),
    do: {:error, :invalid_report}

  defp report!(%Job{} = job, agent, token, type, payload, sequence) do
    case delivered_report(job, agent, sequence) do
      nil -> record_report!(job, agent, token, type, payload, sequence)
      %JobEvent{} = event -> replay_report!(job, agent, token, type, event)
    end
  end

  defp valid_report_sequence?(nil), do: true

  defp valid_report_sequence?(sequence),
    do: is_integer(sequence) and sequence in 1..@max_report_sequence

  defp replay_report!(%Job{} = job, %Agent{} = agent, token, type, %JobEvent{} = event) do
    unless report_token_matches?(job, agent, token), do: Repo.rollback(:lease_not_held)

    if event.type == type, do: job, else: Repo.rollback(:sequence_conflict)
  end

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

  defp report_token_matches?(%Job{} = job, %Agent{} = agent, token)
       when is_binary(token) and is_binary(job.report_token_hash) do
    job.agent_id == agent.id and
      Plug.Crypto.secure_compare(hash_token(token), job.report_token_hash)
  end

  defp report_token_matches?(_job, _agent, _token), do: false

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

  @doc false
  def hash_token(token), do: :crypto.hash(:sha256, token)

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
    |> select([job], {job.organization_id, job.id})
    |> Repo.all()
  end

  # Takes the organization before the job, the order every other job writer
  # and binding change uses. Locking the job first would deadlock with a
  # binding change: it holds the organization FOR UPDATE while it fails the
  # binding's queued jobs, and the job event's foreign key needs KEY SHARE on
  # that same organization row. Disabled organizations' jobs are swept too,
  # so this does not require the organization to be active.
  defp sweep_one({organization_id, job_id}, now, kind) do
    Changes.after_commit(fn ->
      Repo.transaction(fn ->
        Organization
        |> where([organization], organization.id == ^organization_id)
        |> lock("FOR SHARE")
        |> Repo.one()

        Job
        |> where([job], job.id == ^job_id and job.organization_id == ^organization_id)
        |> sweep_condition(kind, now)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()
        |> move!(kind, now)
      end)
    end)
    |> case do
      {:ok, %Job{organization_id: organization_id}} = result ->
        Changes.broadcast(result, organization_id)
        true

      {:ok, nil} ->
        false
    end
  end

  defp move!(nil, _kind, _now), do: nil
  defp move!(%Job{} = job, :lease, now), do: lapse_lease(job, now)
  defp move!(%Job{} = job, :deadline, now), do: expire!(job, now)

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
      %{
        state: next,
        lease_token_hash: nil,
        report_token_hash: nil,
        leased_at: nil,
        lease_expires_at: nil
      }
      |> Map.merge(if next == "queued", do: %{started_at: nil}, else: %{})
      |> Map.merge(if next in Job.finished_states(), do: %{finished_at: now}, else: %{})

    apply!(job, changes, [{"lease_lost", :system, %{"next_state" => next}} | final_events], now)
  end

  ## Resolving uncertain jobs

  @max_note_length 1000

  @doc """
  Records what happened to an `uncertain` job, as a person who checked the
  target and holds the permissions requesting the job needs. `outcome` is `"succeeded"` or `"failed"`. Resolving
  never runs the job again; trying again means requesting a new job.
  """
  def resolve_job(%Scope{} = scope, job_id, outcome, note \\ nil)
      when outcome in ~w(succeeded failed) do
    with {:ok, actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        authorize_for_job!(scope, job_id)
        resolve!(scope.organization_id, job_id, actor, outcome, note_payload(note))
      end)
      |> Changes.broadcast(scope.organization_id)
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
    |> Changes.broadcast(organization_id)
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
    # The purge query spans every organization, so it runs with the
    # background statement timeout rather than the request baseline (RFD 21).
    {:ok, %{num_rows: deleted}} =
      Repo.with_statement_timeout(Repo.background_statement_timeout_ms(), fn query_options ->
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
          [DateTime.to_naive(now), Settings.default_retention_days(), @purge_batch],
          query_options
        )
      end)

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
  long job history is kept; needs `organization.manage`. Allowing a
  capability does not let anyone request it: permissions and, for `operate`
  and `interactive` capabilities, grants still apply.
  """
  def update_settings(%Scope{} = scope, attrs) do
    with {:ok, _actor} <- requesting_user(scope) do
      Repo.transaction(fn ->
        organization = lock_active_organization!(scope.organization_id, :update)
        authorize_member!(scope, "organization.manage")
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

    updated =
      job
      |> Changeset.change(Map.put(changes, :last_sequence, job.last_sequence + length(entries)))
      |> Repo.update!()

    {_count, nil} = Repo.insert_all(JobEvent, entries)
    record_activity!(updated, job.state, events, now)
    # A created or re-queued job wakes its agent, if it is listening.
    if updated.state == "queued", do: Changes.job_queued(updated)
    updated
  end

  # A job requested from a resource shows in that resource's activity, and
  # so in the organization's Activity feed: once when it is requested and
  # once when it reaches an outcome. Progress stays in the job's own history.
  @outcome_states ["uncertain" | Job.finished_states()]

  defp record_activity!(%Job{resource_id: nil}, _previous_state, _events, _now), do: :ok

  defp record_activity!(%Job{} = job, previous_state, events, now) do
    actors = Enum.map(events, fn event -> {elem(event, 0), elem(event, 1)} end)

    for {"created", actor} <- actors, do: insert_activity!(job, "job_requested", actor, now)

    if job.state != previous_state and job.state in @outcome_states do
      {_type, actor} = List.last(actors)
      insert_activity!(job, "job_outcome", actor, now)
    end

    :ok
  end

  defp insert_activity!(%Job{} = job, kind, actor, now) do
    %ChangeEvent{
      organization_id: job.organization_id,
      resource_id: job.resource_id,
      actor_user_id: actor_user_id(actor)
    }
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: Job.capability_key(job),
      metadata: Map.merge(activity_metadata(job), activity_actor(actor)),
      occurred_at: now
    })
    |> Repo.insert!()
  end

  # Activity names the agent that reported an outcome, as it names the
  # source behind a collector's change.
  defp activity_actor({:agent, agent_id}) do
    case Repo.get(Agent, agent_id) do
      %Agent{name: name} when is_binary(name) -> %{"agent" => name}
      _unnamed -> %{}
    end
  end

  defp activity_actor(_actor), do: %{}

  # Activity is a generic feed anyone who sees the resource reads, so a job
  # with sensitive output contributes only its summary (RFD 12): what ran
  # and how it ended, never the agent's reason or result.
  defp activity_metadata(%Job{} = job) do
    summary = %{
      "job_id" => job.id,
      "title" => title(job),
      "noun" => noun(job),
      "state" => job.state
    }

    details =
      if sensitive_output?(job) do
        %{"failure_reason" => job.failure_reason in @system_failure_reasons && job.failure_reason}
      else
        %{
          "failure_reason" => job.failure_reason,
          "observation_id" => job.result && job.result["observation_id"]
        }
      end

    summary
    |> Map.merge(details)
    |> Map.reject(fn {_key, value} -> value in [nil, false] end)
  end

  # A job whose capability is no longer registered is treated as sensitive.
  defp sensitive_output?(%Job{} = job) do
    case Registry.fetch(Job.capability_key(job)) do
      {:ok, capability} -> capability.sensitive_output?()
      {:error, _unknown} -> true
    end
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

  @doc false
  def lock_active_organization!(organization_id, lock \\ :share) do
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
  # scope cannot act after its role was changed. Shared locks keep concurrent
  # job requests from serializing on the organization.
  defp authorize_member!(%Scope{} = scope, permission),
    do: Authorization.authorize!(scope, permission, lock: :share)

  # Stores parameters, results, and payloads exactly as they read back from
  # JSONB, so comparisons (idempotency) and size accounting see one shape.
  defp stringify(value), do: value |> Renga.JSON.encode!() |> Renga.JSON.decode!()
end
