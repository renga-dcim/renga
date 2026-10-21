defmodule Renga.Jobs.TargetBindings do
  @moduledoc """
  Bindings between resources and the installations privileged jobs may run
  on (RFD 13, "Trusted privileged targets").

  An owner or admin binds a resource to an installation that reports it and
  holds an approved key, naming the key's fingerprint as they compared it.
  Binding again replaces the old binding with the next version, and revoking
  ends it; either way queued privileged jobs under the old binding fail
  instead of running somewhere else. Replacing an installation's approved
  key revokes its bindings too, since they named that key.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.Changes
  alias Renga.Inventory.InstallationKey
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Jobs.TargetBinding
  alias Renga.Repo

  @doc "The resource's active binding with its agent and key, or nil."
  def current(%Scope{organization_id: organization_id}, resource_id) do
    TargetBinding
    |> where([binding], binding.organization_id == ^organization_id)
    |> where([binding], binding.resource_id == ^resource_id and binding.status == "active")
    |> preload([:agent, :installation_key])
    |> Repo.one()
  end

  @doc """
  The installations a resource could be bound to: those reporting it whose
  current key is approved, as `{agent, key}` pairs, most recently contacted
  first.
  """
  def candidates(%Scope{organization_id: organization_id}, resource_id) do
    Agent
    |> join(:inner, [agent], key in InstallationKey,
      on:
        key.organization_id == agent.organization_id and key.agent_id == agent.id and
          key.status == "approved"
    )
    |> where([agent], agent.organization_id == ^organization_id and agent.status == "active")
    |> where(
      [agent],
      agent.source_id in subquery(reporting_sources(organization_id, resource_id))
    )
    |> order_by([agent], desc_nulls_last: agent.last_contacted_at, asc: agent.id)
    |> select([agent, key], {agent, key})
    |> Repo.all()
  end

  @doc """
  Binds a resource to an installation as an owner or admin. `fingerprint` is
  the key the person compared; a key replaced in the meantime is refused.
  """
  def bind(%Scope{} = scope, resource_id, agent_id, fingerprint) do
    scope
    |> Inventory.organization_management_transaction(fn ->
      organization_id = scope.organization_id
      lock_resource_bindings!(organization_id, resource_id)
      agent = Repo.get_by(Agent, organization_id: organization_id, id: agent_id)

      key =
        agent &&
          Repo.get_by(InstallationKey,
            organization_id: organization_id,
            agent_id: agent.id,
            status: "approved"
          )

      cond do
        is_nil(agent) or agent.status != "active" ->
          Repo.rollback(:agent_not_found)

        not reports_on?(organization_id, agent, resource_id) ->
          Repo.rollback(:agent_not_for_resource)

        is_nil(key) or key.fingerprint != fingerprint ->
          Repo.rollback(:key_changed)

        true ->
          now = Renga.Time.utc_now_ms()
          previous = active(organization_id, resource_id)

          previous =
            previous &&
              previous
              |> end_binding!("replaced", scope, now)
              |> Repo.preload([:agent, :installation_key])

          binding =
            Repo.insert!(%TargetBinding{
              organization_id: organization_id,
              resource_id: resource_id,
              agent_id: agent.id,
              installation_key_id: key.id,
              version: next_version(organization_id, resource_id),
              status: "active",
              approved_by_user_id: scope.user.id,
              approved_at: now
            })

          record_event!(scope, resource_id, previous, %{
            binding
            | agent: agent,
              installation_key: key
          })

          binding
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc "Ends a resource's binding as an owner or admin."
  def revoke(%Scope{} = scope, binding_id) do
    scope
    |> Inventory.organization_management_transaction(fn ->
      binding =
        TargetBinding
        |> where([binding], binding.organization_id == ^scope.organization_id)
        |> where([binding], binding.id == ^binding_id and binding.status == "active")
        |> lock("FOR UPDATE")
        |> preload([:agent, :installation_key])
        |> Repo.one()

      if is_nil(binding), do: Repo.rollback(:not_found)
      binding = end_binding!(binding, "revoked", scope, Renga.Time.utc_now_ms())
      record_event!(scope, binding.resource_id, binding, nil)
      binding
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc """
  Revokes every binding that names a key being replaced. Runs inside the
  check-in transaction that replaces the key.
  """
  def revoke_for_key!(organization_id, key_id, now) do
    TargetBinding
    |> where([binding], binding.organization_id == ^organization_id)
    |> where([binding], binding.installation_key_id == ^key_id and binding.status == "active")
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(&end_binding!(&1, "key_replaced", nil, now))
  end

  @doc """
  The active binding a privileged job must run under: `agent` must be the
  installation bound to `resource_id`, with its approved key. Runs inside
  job creation and rolls back otherwise.
  """
  def capture!(_organization_id, _agent, nil), do: Repo.rollback(:target_not_bound)

  def capture!(organization_id, %Agent{} = agent, resource_id) do
    case active(organization_id, resource_id) do
      %TargetBinding{agent_id: agent_id} = binding when agent_id == agent.id ->
        unless approved_key?(binding), do: Repo.rollback(:installation_key_not_approved)
        binding

      _missing_or_elsewhere ->
        Repo.rollback(:target_not_bound)
    end
  end

  @doc """
  Whether a privileged job may still be leased by its agent: its binding is
  active at the version it was requested under, and names the agent and an
  approved key. Returns the key to verify the lease signature with.
  """
  def check(%Job{target_binding_id: nil}), do: {:error, :binding_changed}

  def check(%Job{} = job) do
    binding =
      TargetBinding
      |> where([binding], binding.organization_id == ^job.organization_id)
      |> where([binding], binding.id == ^job.target_binding_id)
      |> lock("FOR SHARE")
      |> preload(:installation_key)
      |> Repo.one()

    cond do
      is_nil(binding) or binding.status != "active" -> {:error, :binding_changed}
      binding.version != job.target_binding_version -> {:error, :binding_changed}
      binding.agent_id != job.agent_id -> {:error, :binding_changed}
      binding.installation_key.status != "approved" -> {:error, :installation_key_not_approved}
      true -> {:ok, binding}
    end
  end

  defp end_binding!(binding, reason, scope, now) do
    binding =
      binding
      |> Ecto.Changeset.change(
        status: "revoked",
        revoked_at: now,
        revoked_reason: reason,
        revoked_by_user_id: scope && scope.user && scope.user.id
      )
      |> Repo.update!()

    Jobs.fail_queued_for_binding!(binding.organization_id, binding.id, "binding_changed", now)
    binding
  end

  defp approved_key?(%TargetBinding{} = binding) do
    InstallationKey
    |> where([key], key.organization_id == ^binding.organization_id)
    |> where([key], key.id == ^binding.installation_key_id and key.status == "approved")
    |> Repo.exists?()
  end

  defp active(organization_id, resource_id) do
    TargetBinding
    |> where([binding], binding.organization_id == ^organization_id)
    |> where([binding], binding.resource_id == ^resource_id and binding.status == "active")
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  # Serializes binding changes per resource, so versions never collide.
  defp lock_resource_bindings!(organization_id, resource_id) do
    Inventory.Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> where([resource], resource.id == ^resource_id)
    |> lock("FOR UPDATE")
    |> Repo.one() || Repo.rollback(:resource_not_found)
  end

  defp next_version(organization_id, resource_id) do
    TargetBinding
    |> where([binding], binding.organization_id == ^organization_id)
    |> where([binding], binding.resource_id == ^resource_id)
    |> select([binding], coalesce(max(binding.version), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp reporting_sources(organization_id, resource_id) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id)
    |> where([claim], claim.resource_id == ^resource_id)
    |> select([claim], claim.source_id)
    |> distinct(true)
  end

  defp reports_on?(_organization_id, %Agent{source_id: nil}, _resource_id), do: false

  defp reports_on?(organization_id, %Agent{source_id: source_id}, resource_id) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id)
    |> where([claim], claim.resource_id == ^resource_id and claim.source_id == ^source_id)
    |> Repo.exists?()
  end

  defp record_event!(scope, resource_id, previous, binding) do
    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: "target_binding",
        resource_id: resource_id,
        old_value: binding_value(previous),
        new_value: binding_value(binding),
        occurred_at: Renga.Time.utc_now_ms()
      })
  end

  defp binding_value(nil), do: nil

  defp binding_value(%TargetBinding{} = binding) do
    %{
      "value" => binding.agent.name,
      "fingerprint" => binding.installation_key.fingerprint,
      "version" => binding.version
    }
  end
end
