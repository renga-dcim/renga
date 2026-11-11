defmodule Renga.Jobs.Evidence do
  @moduledoc """
  Protected job evidence, independent of the ordinary intake backlog.

  Lease grant reserves bounded allowance before execution. Submission converts
  unused allowance to immutable work; completion/expiry releases only unused
  allowance. The historical attempt token permits read-only receipt recovery,
  never late submission. Callers hold organization, credential, installation
  and job locks before the capacity advisory lock, then source/lane/work locks.
  """
  import Ecto.Query

  alias Renga.Inventory
  alias Renga.Inventory.ReconciliationWork
  alias Renga.Jobs
  alias Renga.Jobs.EvidenceReservation
  alias Renga.Jobs.Job
  alias Renga.Jobs.Registry
  alias Renga.Repo

  @doc false
  def reserve!(job, agent, token) do
    {:ok, capability} = Registry.fetch(Job.capability_key(job))
    %{items: items, bytes: bytes} = capability.evidence_limit()
    lock_capacity!(job.organization_id)
    limits = Renga.Limits.get_all(job.organization_id)

    if usage(job.organization_id, :items) + items > limits.job_evidence_items or
         usage(job.organization_id, :bytes) + bytes > limits.job_evidence_bytes,
       do: Repo.rollback(:evidence_capacity)

    Repo.insert!(%EvidenceReservation{
      organization_id: job.organization_id,
      job_id: job.id,
      agent_id: agent.id,
      installation_id: agent.installation_id,
      attempt: job.attempts,
      token_hash: Jobs.hash_token(token),
      remaining_items: items,
      remaining_bytes: bytes
    })
  end

  @doc false
  def release_unused!(job) do
    lock_capacity!(job.organization_id)

    Repo.update_all(
      from(r in EvidenceReservation, where: r.job_id == ^job.id and r.attempt == ^job.attempts),
      set: [remaining_items: 0, remaining_bytes: 0]
    )
  end

  @doc "Protected allowance plus accepted work not yet successfully processed."
  def usage(organization_id, dimension) when dimension in [:items, :bytes] do
    remaining = if dimension == :items, do: :remaining_items, else: :remaining_bytes
    charged = if dimension == :items, do: :units, else: :bytes

    unused =
      Repo.one(
        from r in EvidenceReservation,
          where:
            r.organization_id == ^organization_id and
              (r.remaining_items > 0 or r.remaining_bytes > 0),
          select: fragment("COALESCE(sum(?), 0)::bigint", field(r, ^remaining))
      )

    pending =
      Repo.one(
        from w in ReconciliationWork,
          where:
            w.organization_id == ^organization_id and not is_nil(w.job_reservation_id) and
              w.status != "succeeded",
          select: fragment("COALESCE(sum(?), 0)::bigint", field(w, ^charged))
      )

    unused + pending
  end

  @doc "Accept exact encoded host evidence while the job's attempt still owns its lease."
  def submit(scope, key, installation_id, job_id, attempt, token, digest, body) do
    ReconciliationWork.acceptance_transaction(scope, fn ->
      case Inventory.with_intake_agent(
             scope,
             key,
             installation_id,
             &submit_current(scope, key, &1, job_id, attempt, token, digest, body)
           ) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp submit_current(scope, key, agent, job_id, attempt, token, digest, body) do
    Repo.transaction(fn ->
      job = lock_job!(scope.organization_id, agent.id, job_id)
      reservation = authority!(job, agent, attempt, token)
      now = Repo.query!("SELECT clock_timestamp()").rows |> hd() |> hd()

      unless job.attempts == attempt and job.state in Job.leased_states() and
               DateTime.compare(job.lease_expires_at, now) == :gt and
               Plug.Crypto.secure_compare(Jobs.hash_token(token), job.lease_token_hash),
             do: Repo.rollback(:lease_not_held)

      {:ok, capability} = Registry.fetch(Job.capability_key(job))
      if capability.evidence_limit().items == 0, do: Repo.rollback(:evidence_not_allowed)

      params = submitted_params!(digest, body)
      lock_capacity!(scope.organization_id)

      accepted =
        ReconciliationWork.accept_job_evidence!(scope, key, agent, reservation, digest, params)

      # Lock waits and validation cannot turn a once-current lease into late admission.
      unless Repo.exists?(
               from j in Job,
                 where:
                   j.id == ^job.id and
                     j.lease_expires_at > fragment("clock_timestamp()")
             ),
             do: Repo.rollback(:lease_not_held)

      accepted
    end)
  end

  defp submitted_params!(digest, body) do
    unless is_binary(body) and is_binary(digest) and sha256(body) == digest,
      do: Repo.rollback(:invalid_evidence)

    if byte_size(body) > Inventory.AgentPayload.max_observation_bytes(),
      do: Repo.rollback(:evidence_limit_exceeded)

    case Jason.decode(body) do
      {:ok, %{} = params} -> params
      _ -> Repo.rollback(:invalid_evidence)
    end
  end

  @doc "Inspect an exact accepted body after expiry without admitting or renewing anything."
  def receipt(scope, agent, job_id, attempt, token, digest, observation_id) do
    Repo.transaction(fn ->
      reservation =
        authority!(%{id: job_id, organization_id: scope.organization_id}, agent, attempt, token)

      work =
        Repo.one(
          from w in ReconciliationWork,
            join: o in Inventory.Observation,
            on: o.id == w.observation_id,
            where:
              w.job_reservation_id == ^reservation.id and w.job_body_digest == ^digest and
                o.idempotency_key == ^observation_id and
                w.organization_id == ^scope.organization_id
        )

      if is_nil(work), do: Repo.rollback(:not_found)
      {Repo.get!(Inventory.Observation, work.observation_id), :duplicate}
    end)
  end

  @doc false
  def require_result!(job, result) do
    {:ok, capability} = Registry.fetch(Job.capability_key(job))

    # A redelivered job resends its durable outcome, even on a later attempt.
    # It may reuse its own accepted evidence, never another job's observation.
    for id <- capability.result_evidence_ids(result) do
      accepted? =
        Repo.exists?(
          from w in ReconciliationWork,
            join: r in EvidenceReservation,
            on: r.id == w.job_reservation_id,
            join: o in Inventory.Observation,
            on: o.id == w.observation_id,
            where:
              r.job_id == ^job.id and r.agent_id == ^job.agent_id and
                r.organization_id == ^job.organization_id and o.idempotency_key == ^id
        )

      unless accepted?, do: Repo.rollback(:evidence_not_accepted)
    end
  end

  defp authority!(job, agent, attempt, token) do
    reservation =
      Repo.one(
        from r in EvidenceReservation,
          where:
            r.organization_id == ^job.organization_id and r.job_id == ^job.id and
              r.attempt == ^attempt and r.agent_id == ^agent.id and
              r.installation_id == ^agent.installation_id,
          lock: "FOR UPDATE"
      )

    unless reservation && is_binary(token) &&
             Plug.Crypto.secure_compare(reservation.token_hash, Jobs.hash_token(token)),
           do: Repo.rollback(:lease_not_held)

    reservation
  end

  defp lock_job!(organization_id, agent_id, job_id) do
    Repo.one(
      from j in Job,
        where:
          j.organization_id == ^organization_id and j.agent_id == ^agent_id and j.id == ^job_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp lock_capacity!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 212115))", [organization_id])
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
