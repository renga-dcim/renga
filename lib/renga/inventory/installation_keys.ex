defmodule Renga.Inventory.InstallationKeys do
  @moduledoc """
  Installation keys (RFD 13, "Installation credentials").

  Each installation presents an Ed25519 public key on check-in. The first key
  Renga sees is pending; an owner or admin approves it on the Collectors page
  after comparing the fingerprint the agent prints locally. A different key
  replaces the current one and returns the installation to pending. When the
  replaced key was approved, a collector finding opens on every resource the
  installation reports, and approving the new key resolves it.

  A holder of the intake key can always present a new key, so the worst it
  can do here is return an installation to pending, never approve one.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.Changes
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.InstallationKey
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Repo

  @doc """
  Records the key an installation presented on check-in. Runs inside the
  check-in transaction, after the agent row is locked.
  """
  def present!(%Agent{} = agent, %{algorithm: algorithm, public_key: public_key}, now) do
    current = lock_current(agent.organization_id, agent.id)

    cond do
      is_nil(current) ->
        insert_pending!(agent, algorithm, public_key, now)

      current.algorithm == algorithm and current.public_key == public_key ->
        current
        |> Ecto.Changeset.change(last_presented_at: now)
        |> Repo.update!()

      true ->
        replace!(agent, current, algorithm, public_key, now)
    end
  end

  @doc "The current key of each listed agent, pending or approved, by agent id."
  def current_by_agent(%Scope{organization_id: organization_id}, agent_ids) do
    InstallationKey
    |> where([key], key.organization_id == ^organization_id and key.agent_id in ^agent_ids)
    |> where([key], key.status in ["pending", "approved"])
    |> Repo.all()
    |> Map.new(&{&1.agent_id, &1})
  end

  @doc "The agent's current key, pending or approved, or nil."
  def current(%Scope{organization_id: organization_id}, agent_id) do
    InstallationKey
    |> where([key], key.organization_id == ^organization_id and key.agent_id == ^agent_id)
    |> where([key], key.status in ["pending", "approved"])
    |> Repo.one()
  end

  @doc """
  Approves a pending key; it needs `intake_keys.manage`, which owners and
  admins hold. `fingerprint` is the one the person saw when deciding, so a
  key replaced in the meantime is refused rather than approved unseen.
  """
  def approve(%Scope{} = scope, key_id, fingerprint) do
    scope
    |> Inventory.organization_management_transaction("intake_keys.manage", fn ->
      key =
        InstallationKey
        |> where([key], key.organization_id == ^scope.organization_id and key.id == ^key_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      approve_key!(scope, key, fingerprint)
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  defp approve_key!(
         scope,
         %InstallationKey{status: "pending", fingerprint: fingerprint} = key,
         fingerprint
       ) do
    now = Renga.Time.utc_now_ms()

    key =
      key
      |> Ecto.Changeset.change(
        status: "approved",
        approved_at: now,
        approved_by_user_id: scope.user.id
      )
      |> Repo.update!()

    resolve_findings!(key.organization_id, key.agent_id, now)
    record_event!(scope, key.agent_id, nil, key.fingerprint, "approved")
    key
  end

  defp approve_key!(_scope, %InstallationKey{}, _fingerprint), do: Repo.rollback(:key_changed)
  defp approve_key!(_scope, nil, _fingerprint), do: Repo.rollback(:not_found)

  defp lock_current(organization_id, agent_id) do
    InstallationKey
    |> where([key], key.organization_id == ^organization_id and key.agent_id == ^agent_id)
    |> where([key], key.status in ["pending", "approved"])
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_pending!(agent, algorithm, public_key, now) do
    Repo.insert!(%InstallationKey{
      organization_id: agent.organization_id,
      agent_id: agent.id,
      algorithm: algorithm,
      public_key: public_key,
      fingerprint: InstallationKey.fingerprint(public_key),
      status: "pending",
      first_presented_at: now,
      last_presented_at: now
    })
  end

  defp replace!(agent, current, algorithm, public_key, now) do
    current
    |> Ecto.Changeset.change(status: "replaced", replaced_at: now)
    |> Repo.update!()

    # Bindings named the old key, so none of them carries over (RFD 13).
    Renga.Jobs.TargetBindings.revoke_for_key!(agent.organization_id, current.id, now)

    key = insert_pending!(agent, algorithm, public_key, now)
    scope = %Scope{organization_id: agent.organization_id}
    record_event!(scope, agent.id, current.fingerprint, key.fingerprint, "pending")

    if current.status == "approved",
      do: open_findings!(agent, current, key, now),
      else: retarget_open_findings!(agent, key, now)

    key
  end

  # A finding opened by an earlier change must name the key now awaiting
  # approval, or the Inbox would ask people to compare a fingerprint that is
  # no longer current. `previous_fingerprint` stays the last approved key.
  defp retarget_open_findings!(agent, key, now) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^agent.organization_id)
    |> where([finding], finding.agent_id == ^agent.id and finding.status == "open")
    |> where([finding], finding.kind == "installation_key_changed")
    |> update([finding],
      set: [
        details:
          fragment(
            "jsonb_set(?, '{fingerprint}', to_jsonb(?::text))",
            finding.details,
            ^key.fingerprint
          ),
        last_observed_at: ^now,
        updated_at: ^now
      ]
    )
    |> Repo.update_all([])
  end

  defp open_findings!(agent, previous, key, now) do
    details = %{
      "installation_id" => agent.installation_id,
      "previous_fingerprint" => previous.fingerprint,
      "fingerprint" => key.fingerprint
    }

    entries =
      agent
      |> reported_resource_ids()
      |> Enum.map(fn resource_id ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: agent.organization_id,
          resource_id: resource_id,
          agent_id: agent.id,
          kind: "installation_key_changed",
          status: "open",
          message:
            "#{agent.name} presented a new installation key; privileged jobs wait until it is approved",
          details: details,
          last_observed_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(CollectorFinding, entries,
      on_conflict: {:replace, [:message, :details, :last_observed_at, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(organization_id, resource_id, agent_id, kind) WHERE status = 'open'"}
    )
  end

  defp reported_resource_ids(%Agent{source_id: nil}), do: []

  defp reported_resource_ids(%Agent{organization_id: organization_id, source_id: source_id}) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id and claim.source_id == ^source_id)
    |> distinct(true)
    |> select([claim], claim.resource_id)
    |> Repo.all()
  end

  defp resolve_findings!(organization_id, agent_id, now) do
    CollectorFinding
    |> where([finding], finding.organization_id == ^organization_id)
    |> where([finding], finding.agent_id == ^agent_id and finding.status == "open")
    |> where([finding], finding.kind == "installation_key_changed")
    |> Repo.update_all(set: [status: "resolved", resolved_at: now, updated_at: now])
  end

  defp record_event!(scope, agent_id, old_fingerprint, new_fingerprint, status) do
    source_id =
      Repo.one!(from agent in Agent, where: agent.id == ^agent_id, select: agent.source_id)

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "updated",
        field: "installation_key",
        source_id: source_id,
        old_value: old_fingerprint && %{"value" => old_fingerprint},
        new_value: %{"value" => new_fingerprint},
        metadata: %{"status" => status},
        occurred_at: Renga.Time.utc_now_ms()
      })
  end
end
