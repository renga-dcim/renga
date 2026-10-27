defmodule Renga.Operators.OrganizationLifecycle do
  @moduledoc """
  Operator containment and the recoverable deletion boundary (RFD 22).

  The organization row serializes access, cancellation, and purge. `disabled`
  is suspension, not deletion. A pending deletion has one immutable deadline;
  cancelling or resuming restores access without rerunning cancelled work.
  Purging is a committed, irreversible state, retried after worker failure.
  """
  import Ecto.Query
  require Logger

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.DeploymentAudit
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo

  @actions ~w(suspend resume schedule_deletion cancel_deletion)

  def available?(id) do
    Repo.exists?(from o in Organization, where: o.id == ^id and o.status == "active")
  end

  def topic(id), do: "organization_lifecycle:#{id}"

  @doc "Idempotently applies a target state, auditing refusals as well as successes."
  def change(id, action, context) when action in @actions do
    do_change(id, action, context, nil)
  end

  @doc "Owner recovery, using the freshly authenticated HTTP user, not an operator credential."
  def cancel_by_owner(user, id, request_id) do
    do_change(id, "cancel_deletion", %{actor: {:user, user}, invocation_id: request_id}, user)
  end

  defp do_change(id, action, context, user) do
    run =
      fn ->
        DeploymentAudit.mutate(context, "organization.#{action}", fn ->
          with {:ok, organization} <- lock(id),
               :ok <- if(is_nil(user), do: :ok, else: owner_check(user, organization)),
               {:ok, attrs} <- transition(organization, action) do
            changed = Map.keys(attrs)
            if attrs[:status] == "active", do: reconcile_sources!(organization.id)
            updated = organization |> Ecto.Changeset.change(attrs) |> Repo.update!()

            if changed != [] do
              if updated.status != "active", do: Renga.Jobs.suspend_organization!(updated.id)
              activity!(updated, action, context)
              # Delivered at commit to every application VM, including when
              # this mutation runs in the repository-only release command VM.
              Repo.query!("SELECT pg_notify('renga_organization_lifecycle', $1)", [id])

              if action in ~w(schedule_deletion cancel_deletion) or
                   (action == "resume" and organization.status == "deletion_pending"),
                 do: enqueue_notices!(updated, action)
            end

            {:ok, {updated, changed != []},
             %{organization: updated, target_id: id, changed: changed}}
          else
            {:error, reason} -> {:error, reason, %{target_id: id}}
          end
        end)
      end

    result = if Process.whereis(Renga.PubSub), do: Renga.Scim.Grants.announcing(run), else: run.()

    case result do
      {:ok, {organization, true}} ->
        publish(id)
        {:ok, organization}

      {:ok, {organization, false}} ->
        {:ok, organization}

      error ->
        error
    end
  end

  @doc false
  def publish(id) do
    if Process.whereis(Renga.PubSub) do
      Phoenix.PubSub.local_broadcast(
        Renga.PubSub,
        topic(id),
        {:organization_lifecycle_changed, id}
      )

      unless available?(id) do
        Phoenix.PubSub.local_broadcast(
          Renga.PubSub,
          "organization_agents:#{id}",
          %Phoenix.Socket.Broadcast{
            topic: "organization_agents:#{id}",
            event: "disconnect",
            payload: %{}
          }
        )
      end
    end

    :ok
  end

  defp transition(%{status: "purging"}, _action), do: {:error, :purging}
  defp transition(%{status: "active"}, "resume"), do: {:ok, %{}}
  defp transition(%{status: status}, "suspend") when status != "active", do: {:ok, %{}}
  defp transition(_organization, "suspend"), do: {:ok, %{status: "disabled"}}
  defp transition(_organization, "resume"), do: {:ok, clear_deletion("active")}
  defp transition(%{status: "deletion_pending"}, "schedule_deletion"), do: {:ok, %{}}

  defp transition(_organization, "schedule_deletion") do
    now = Renga.Time.utc_now_ms()

    {:ok,
     %{
       status: "deletion_pending",
       deletion_scheduled_at: now,
       deletion_due_at: DateTime.add(now, 30, :day)
     }}
  end

  defp transition(%{status: "deletion_pending"}, "cancel_deletion"),
    do: {:ok, clear_deletion("active")}

  defp transition(_organization, "cancel_deletion"), do: {:ok, %{}}

  defp clear_deletion(status),
    do: %{status: status, deletion_scheduled_at: nil, deletion_due_at: nil}

  @doc "Pending organizations this authenticated owner may recover, without ordinary tenant access."
  def pending_for_owner(user) do
    Organization
    |> join(:inner, [o], m in OrganizationMembership, on: m.organization_id == o.id)
    |> where([o, m], o.status == "deletion_pending" and m.user_id == ^user.id)
    |> where([_o, m], m.status == "active" and m.role == "owner")
    |> select([o, m], {o, m})
    |> Repo.all()
    |> Enum.filter(fn {organization, membership} ->
      (is_nil(user.session_organization_id) or user.session_organization_id == organization.id) and
        Renga.Accounts.OrganizationMFA.satisfied?(user, organization.id) and
        source_owner?(membership)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Restricted export scope; never installs a tenant in the browser session."
  def owner_scope(user, id) do
    Repo.transaction(fn ->
      with {:ok, %Organization{status: "deletion_pending"} = organization} <- lock(id),
           :ok <- owner_check(user, organization) do
        membership = Accounts.get_membership_for_user(organization, user.id)
        Renga.Accounts.Scope.for_membership(user, organization, membership)
      else
        _ -> Repo.rollback(:forbidden)
      end
    end)
  end

  @doc false
  def authorize_export!(scope) do
    with {:ok, %Organization{status: "deletion_pending"} = organization} <-
           lock(scope.organization_id),
         :ok <- owner_check(scope.user, organization) do
      :ok
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp owner_check(nil, _organization), do: {:error, :forbidden}

  defp owner_check(user, organization) do
    membership =
      Repo.one(
        from m in OrganizationMembership,
          where: m.organization_id == ^organization.id and m.user_id == ^user.id,
          where: m.status == "active" and m.role == "owner",
          lock: "FOR UPDATE"
      )

    if membership && source_owner?(membership) &&
         (is_nil(user.session_organization_id) or user.session_organization_id == organization.id) &&
         Renga.Accounts.OrganizationMFA.satisfied?(user, organization.id),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp source_owner?(%{scim_connection_id: nil}), do: true

  defp source_owner?(membership),
    do: Renga.Scim.Grants.granted_role(membership.organization_id, membership.user_id) == "owner"

  # Source reductions may have occurred while the organization was suspended.
  # Reconcile before access returns, in the same transaction and lock order.
  defp reconcile_sources!(id) do
    Repo.all(from c in Renga.Scim.Connection, where: c.organization_id == ^id)
    |> Enum.flat_map(&Renga.Scim.Grants.users_of_connection/1)
    |> Enum.uniq()
    |> then(&Renga.Scim.Grants.reconcile!(id, &1, %{"reason" => "organization_resumed"}))
  end

  defp lock(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Organization{} = organization <-
           Repo.one(from o in Organization, where: o.id == ^id, lock: "FOR UPDATE") do
      {:ok, organization}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Marks due tenants purging under the same lock as cancellation, then retries purge."
  def sweep do
    now = Renga.Time.utc_now_ms()

    ids =
      Repo.all(
        from o in Organization,
          where:
            o.status == "purging" or
              (o.status == "deletion_pending" and o.deletion_due_at <= ^now),
          order_by: [asc: o.deletion_due_at, asc: o.id],
          limit: 20,
          select: o.id
      )

    Enum.each(ids, fn id ->
      try do
        purge_due(id, now)
      rescue
        error -> Logger.error("Organization purge #{id} failed: #{Exception.message(error)}")
      end
    end)
  end

  def purge_due(id, now \\ Renga.Time.utc_now_ms()) do
    context = DeploymentAudit.operator("organization lifecycle worker")

    with {:ok, _organization} <-
           DeploymentAudit.mutate(context, "organization.begin_purge", fn ->
             with {:ok, organization} <- lock(id),
                  true <-
                    organization.status == "purging" or
                      (organization.status == "deletion_pending" and
                         DateTime.compare(organization.deletion_due_at, now) != :gt) do
               updated =
                 organization |> Ecto.Changeset.change(status: "purging") |> Repo.update!()

               {:ok, updated, %{organization: updated, target_id: id, changed: [:status]}}
             else
               _ -> {:error, :not_due, %{target_id: id}}
             end
           end) do
      DeploymentAudit.mutate(context, "organization.purge", fn ->
        # Provider changes/sign-ins lock providers before organizations. Keep
        # that order while retiring credentials; provider scope tombstones stay.
        result =
          Renga.Accounts.IdentityProviders.locked(nil, fn ->
            providers =
              Repo.all(
                from p in Renga.Accounts.IdentityProvider,
                  where: p.organization_id == ^id,
                  order_by: p.id,
                  lock: "FOR UPDATE"
              )

            with {:ok, %Organization{status: "purging"} = organization} <- lock(id) do
              for provider <- providers, is_nil(provider.removed_at) do
                {:ok, _} =
                  Renga.Accounts.IdentityProviders.remove(
                    provider,
                    {:operator, "organization lifecycle worker"}
                  )
              end

              # Tenant foreign keys cascade, including archive chunks. Users,
              # provider identity tombstones and deployment attribution survive.
              Repo.delete!(organization)
              {:ok, organization}
            else
              _ -> {:error, :not_found}
            end
          end)

        case result do
          {:ok, organization} ->
            {:ok, organization,
             %{organization: organization, target_id: id, changed: [:organization]}}

          {:error, reason} ->
            {:error, reason, %{target_id: id}}
        end
      end)
    end
  end

  defp activity!(organization, action, context) do
    %ChangeEvent{organization_id: organization.id, actor_user_id: user_id(context.actor)}
    |> ChangeEvent.changeset(%{
      kind: "updated",
      field: "organization_lifecycle",
      new_value: %{"status" => organization.status},
      metadata: %{
        "operator" => DeploymentAudit.actor_label(context),
        "operation" => action,
        "invocation_id" => context.invocation_id,
        "operator_token_id" => token_id(context.actor)
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp token_id({:token, token}), do: token.id
  defp token_id({:operator, _}), do: nil
  defp token_id({:user, _}), do: nil

  defp user_id({:user, user}), do: user.id
  defp user_id(_), do: nil

  defp enqueue_notices!(organization, action) do
    users =
      Repo.all(
        from m in OrganizationMembership,
          join: u in assoc(m, :user),
          where:
            m.organization_id == ^organization.id and m.status == "active" and m.role == "owner",
          select: u
      )
      |> Accounts.put_organization_emails(organization.id)

    for user <- users, email = user.email || user.organization_email, is_binary(email) do
      Repo.insert_all("organization_lifecycle_notices", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          organization_id: Ecto.UUID.dump!(organization.id),
          recipient: email,
          organization_name: organization.name,
          operation: action,
          deadline: organization.deletion_due_at
        }
      ])
    end
  end

  @doc "At-least-once owner notification delivery; committed state never depends on SMTP."
  def deliver_notices do
    Repo.transaction(fn ->
      notices =
        Repo.all(
          from n in "organization_lifecycle_notices",
            where: is_nil(n.delivered_at),
            lock: "FOR UPDATE SKIP LOCKED",
            limit: 20,
            select: map(n, [:id, :recipient, :organization_name, :operation, :deadline])
        )

      Enum.each(notices, fn notice ->
        case Renga.Accounts.UserNotifier.deliver_organization_lifecycle(notice) do
          {:ok, _} ->
            Repo.update_all(
              from(n in "organization_lifecycle_notices", where: n.id == ^notice.id),
              set: [delivered_at: Renga.Time.utc_now_ms()]
            )

          {:error, _} ->
            :ok
        end
      end)
    end)
  end
end
