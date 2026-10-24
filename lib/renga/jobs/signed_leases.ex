defmodule Renga.Jobs.SignedLeases do
  @moduledoc """
  Leasing `operate` and `interactive` jobs (RFD 13, "Installation
  credentials").

  The intake key proves only the organization, so a privileged job is never
  leased on it alone. Leasing takes two requests:

    1. `offer/4` hands the agent a lease token and a fresh nonce for each
       queued privileged job it could run, without the job's parameters.
    2. `claim/6` leases the job only when the agent signs `message/6` over
       the job, token, nonce, installation, resource, and binding version
       with its approved key.

  Each step rechecks the job's target binding, so a job whose binding ended
  or changed fails instead of running, and one whose key awaits approval
  stays queued. A new offer replaces the previous one, and an offer lapses
  after a minute.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Agent
  alias Renga.Inventory.InstallationKey
  alias Renga.Jobs
  alias Renga.Jobs.Changes
  alias Renga.Jobs.Job
  alias Renga.Jobs.Settings
  alias Renga.Jobs.TargetBindings
  alias Renga.Repo

  @offer_seconds 60
  @context "renga-job-lease-v1"

  @doc """
  The bytes an agent signs to claim an offer: a context line, then each
  field on its own line.
  """
  def message(job_id, lease_token, nonce, installation_id, resource_id, binding_version) do
    Enum.join(
      [
        @context,
        job_id,
        lease_token,
        nonce,
        installation_id,
        resource_id,
        Integer.to_string(binding_version)
      ],
      "\n"
    ) <> "\n"
  end

  @doc """
  Offers up to `limit` queued privileged jobs among `keys` to `agent`. An
  agent without an approved key gets no offers.
  """
  def offer(%Scope{organization_id: organization_id}, %Agent{} = agent, keys, limit)
      when is_list(keys) and is_integer(limit) and limit > 0 do
    if agent.organization_id != organization_id do
      {:error, :forbidden}
    else
      organization_id
      |> offer_transaction(agent, keys, limit)
      |> announce(organization_id)
    end
  end

  defp offer_transaction(organization_id, agent, keys, limit) do
    Repo.transaction(fn ->
      organization = Jobs.lock_active_organization!(organization_id)
      now = Renga.Time.utc_now_ms()

      if approved_key(agent) do
        allowed = Settings.allowed_capabilities(organization)

        jobs =
          organization_id
          |> Jobs.leasable_jobs(agent, keys, limit, now)
          |> where([job], job.risk_class != "observe")
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()

        results = Enum.map(jobs, &offer_job!(&1, allowed, now))
        {for({:offered, offer} <- results, do: offer), Enum.any?(results, &(&1 == :refused))}
      else
        {[], false}
      end
    end)
  end

  defp offer_job!(job, allowed, now) do
    with true <- Job.capability_key(job) in allowed || :not_allowed,
         {:ok, _binding} <- TargetBindings.check(job) do
      token = Jobs.new_token()
      nonce = Jobs.new_token()
      expires_at = DateTime.add(now, @offer_seconds)

      job =
        job
        |> Ecto.Changeset.change(
          offer_token_hash: Jobs.hash_token(token),
          offer_nonce: nonce,
          offer_expires_at: expires_at
        )
        |> Repo.update!()

      {:offered, %{job: job, lease_token: token, nonce: nonce, expires_at: expires_at}}
    else
      :not_allowed ->
        Jobs.refuse!(job, "capability_not_allowed", now)
        :refused

      {:error, :binding_changed} ->
        Jobs.refuse!(job, "binding_changed", now)
        :refused

      # The installation's key awaits approval; the job waits with it.
      {:error, :installation_key_not_approved} ->
        :waiting
    end
  end

  @doc """
  Leases an offered job when `signature` is the agent's approved key's
  Ed25519 signature over `message/6`. Returns `{:ok, {job, lease_token}}`
  like `Renga.Jobs.lease_jobs/4`, or `{:ok, {:failed, reason}}` when the job
  failed instead (`:binding_changed` or `:capability_not_allowed`), which
  commits.

  Callers run this inside `Renga.Inventory.with_intake_agent/4`, whose
  agent row lock serializes the claim with a check-in replacing the key.
  """
  def claim(
        %Scope{organization_id: organization_id},
        %Agent{} = agent,
        job_id,
        token,
        nonce,
        signature
      ) do
    organization_id
    |> claim_transaction(agent, job_id, token, nonce, signature)
    |> Changes.broadcast(organization_id)
  end

  defp claim_transaction(organization_id, agent, job_id, token, nonce, signature) do
    Repo.transaction(fn ->
      organization = Jobs.lock_active_organization!(organization_id)
      now = Renga.Time.utc_now_ms()
      job = lock_job(organization_id, agent, job_id) || Repo.rollback(:not_found)

      unless current_offer?(job, token, nonce, now), do: Repo.rollback(:offer_invalid)

      # Policy applies when the job leases, not when it was offered, so a
      # capability withdrawn since the offer fails the job as a plain lease
      # would.
      allowed? = Job.capability_key(job) in Settings.allowed_capabilities(organization)

      case allowed? && TargetBindings.check(job) do
        false ->
          Jobs.refuse!(job, "capability_not_allowed", now)
          {:failed, :capability_not_allowed}

        {:ok, binding} ->
          verify!(job, agent, token, nonce, signature, binding.installation_key)

          job
          |> Ecto.Changeset.change(offer_token_hash: nil, offer_nonce: nil, offer_expires_at: nil)
          |> Repo.update!()
          |> Jobs.lease_with_token!(agent, token, now)

        {:error, :binding_changed} ->
          Jobs.refuse!(job, "binding_changed", now)
          {:failed, :binding_changed}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp lock_job(organization_id, agent, job_id) do
    case Ecto.UUID.cast(job_id) do
      {:ok, job_id} ->
        Job
        |> where([job], job.organization_id == ^organization_id and job.id == ^job_id)
        |> where([job], job.agent_id == ^agent.id and is_nil(job.imported_at))
        |> lock("FOR UPDATE")
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp current_offer?(%Job{state: "queued", offer_token_hash: hash} = job, token, nonce, now)
       when is_binary(hash) and is_binary(token) and is_binary(nonce) do
    DateTime.after?(job.offer_expires_at, now) and DateTime.after?(job.not_after, now) and
      Plug.Crypto.secure_compare(hash, Jobs.hash_token(token)) and
      Plug.Crypto.secure_compare(job.offer_nonce, nonce)
  end

  defp current_offer?(_job, _token, _nonce, _now), do: false

  defp verify!(job, agent, token, nonce, signature, key) do
    unless verified?(job, agent, token, nonce, signature, key),
      do: Repo.rollback(:signature_invalid)
  end

  defp verified?(job, agent, token, nonce, signature, %InstallationKey{
         algorithm: "ed25519",
         public_key: key
       })
       when is_binary(signature) and byte_size(signature) == 64 do
    message =
      message(
        job.id,
        token,
        nonce,
        agent.installation_id,
        job.resource_id,
        job.target_binding_version
      )

    :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519])
  end

  defp verified?(_job, _agent, _token, _nonce, _signature, _key), do: false

  defp approved_key(%Agent{} = agent) do
    InstallationKey
    |> where([key], key.organization_id == ^agent.organization_id and key.agent_id == ^agent.id)
    |> where([key], key.status == "approved")
    |> Repo.one()
  end

  defp announce({:ok, {offers, true}}, organization_id),
    do: Changes.broadcast({:ok, offers}, organization_id)

  defp announce({:ok, {offers, false}}, _organization_id), do: {:ok, offers}
  defp announce(error, _organization_id), do: error
end
