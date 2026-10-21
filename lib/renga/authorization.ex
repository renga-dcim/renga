defmodule Renga.Authorization do
  @moduledoc """
  The single place that answers "may this scope do this?" (RFD 17).

  A permission names one kind of action, such as `"inventory.edit"`. The
  catalogue is defined here, in code; organizations cannot add to it. A role
  is a named set of permissions, and today every membership holds exactly one
  of the four built-in roles, which reproduce the behavior of the role lists
  the contexts used to check.

  Two entry points answer the question:

    * `allowed?/3` reads the roles cached in the scope. It is a UI hint and
      never a boundary.
    * `authorize!/3` runs inside the context transaction that performs the
      change. It locks the organization (which must be active) and then the
      membership, re-reading the role from the database, and rolls the
      transaction back with `:forbidden` when the permission is missing.
      Every context takes those two locks in that order so concurrent
      mutations cannot deadlock.

  Machine work (agents' reconcilers, triage rule application) runs as fixed
  internal principals instead of people. They hold no catalogue permissions
  and are checked with `authorize_system!/2`, so a principal can only run the
  paths that name it.

  Conditions and custom roles arrive later; until then every grant covers the
  whole organization, so `allowed?/3` accepts a target but does not consult
  it.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Repo

  @permissions [
    "inventory.read",
    "inventory.reconcile",
    "inventory.edit",
    "findings.act",
    "requests.create",
    "requests.decide",
    "catalog.author",
    "catalog.expectations",
    "dcim.edit",
    "ipam.edit",
    "topology.edit",
    "jobs.request",
    "views.share",
    "teams.manage",
    "triage_rules.manage",
    "intake_keys.manage",
    "members.manage",
    "roles.manage",
    "organization.manage",
    "organization.export"
  ]

  @workflow ~w(inventory.reconcile findings.act catalog.author)
  @management ~w(inventory.edit requests.decide catalog.expectations dcim.edit ipam.edit
                 topology.edit jobs.request views.share teams.manage triage_rules.manage
                 intake_keys.manage members.manage roles.manage)
  @organization ~w(organization.manage organization.export)

  # Built-in roles keep the behavior of the hard-coded role lists exactly.
  # `requests.create` is member-only: owners and admins make the change
  # directly instead of proposing it.
  @built_in_roles %{
    "owner" => ["inventory.read"] ++ @workflow ++ @management ++ @organization,
    "admin" => ["inventory.read"] ++ @workflow ++ @management,
    "member" => ["inventory.read"] ++ @workflow ++ ["requests.create"],
    "viewer" => ["inventory.read"]
  }

  @role_order ~w(owner admin member viewer)

  # Fixed internal principals. Each is carried in a scope without a user and
  # authorizes only the system paths that name it.
  @machine_principals ~w(catalog_reconciler placement_reconciler topology_reconciler triage_rules)

  @doc "Every permission in the catalogue."
  def permissions, do: @permissions

  @doc "The built-in role names, most privileged first."
  def built_in_roles, do: @role_order

  @doc "The permissions a built-in role grants."
  def role_permissions(role) when is_map_key(@built_in_roles, role),
    do: Map.fetch!(@built_in_roles, role)

  @doc """
  The built-in roles that grant `permission`, most privileged first.

  For queries that pick people by what they may do, such as an assignee
  picker.
  """
  def roles_granting(permission) do
    permission = validate!(permission)
    Enum.filter(@role_order, &(permission in Map.fetch!(@built_in_roles, &1)))
  end

  @doc "The fixed internal principals machine scopes run as."
  def machine_principals, do: @machine_principals

  @doc """
  Whether the scope's cached roles grant `permission`.

  Only people hold permissions; a machine scope is never allowed. Use this for
  UI hints only: the transaction check in `authorize!/3` is authoritative.
  """
  def allowed?(scope, permission, target \\ nil)

  def allowed?(%Scope{user: %{}, roles: roles}, permission, _target) do
    granting = roles_granting(permission)
    Enum.any?(roles || [], &(&1 in granting))
  end

  def allowed?(_scope, permission, _target) do
    validate!(permission)
    false
  end

  @doc """
  Requires `permission` inside the current transaction.

  Locks the scope's organization, requiring it to be active, then the
  scope's own active membership, and checks the membership's current role.
  Rolls the transaction back with `:forbidden` otherwise.

  Options:

    * `:lock` - `:update` (the default) takes both locks `FOR UPDATE`, which
      serializes with every other managed mutation in the organization;
      `:share` takes them `FOR SHARE`, for high-volume paths such as job
      requests that only need the organization and membership to stay put.
  """
  def authorize!(scope, permission, opts \\ [])

  def authorize!(
        %Scope{membership_id: membership_id, user: %{id: user_id}} = scope,
        permission,
        opts
      )
      when not is_nil(membership_id) do
    granting = roles_granting(permission)
    mode = Keyword.get(opts, :lock, :update)
    lock_active_organization!(scope.organization_id, mode)

    OrganizationMembership
    |> where([membership], membership.id == ^membership_id)
    |> where([membership], membership.user_id == ^user_id)
    |> where([membership], membership.organization_id == ^scope.organization_id)
    |> where([membership], membership.status == "active")
    |> where([membership], membership.role in ^granting)
    |> select([membership], membership.id)
    |> row_lock(mode)
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:forbidden)
      _membership_id -> :ok
    end
  end

  def authorize!(%Scope{}, permission, _opts) do
    validate!(permission)
    Repo.rollback(:forbidden)
  end

  @doc """
  Requires the scope to be the machine `principal` inside the current
  transaction, locking its organization, which must be active.
  """
  def authorize_system!(
        %Scope{user: nil, roles: roles, organization_id: organization_id},
        principal
      )
      when principal in @machine_principals do
    if principal in (roles || []) do
      lock_active_organization!(organization_id)
    else
      Repo.rollback(:forbidden)
    end
  end

  def authorize_system!(%Scope{}, principal) when principal in @machine_principals,
    do: Repo.rollback(:forbidden)

  @doc false
  # Shared with contexts that lock the organization on paths that are not
  # authorization checks, so every caller takes the lock the same way.
  def lock_active_organization!(organization_id, mode \\ :update) do
    Organization
    |> where([organization], organization.id == ^organization_id)
    |> select([organization], organization.status)
    |> row_lock(mode)
    |> Repo.one()
    |> case do
      "active" -> :ok
      _inactive_or_missing -> Repo.rollback(:forbidden)
    end
  end

  defp row_lock(query, :update), do: lock(query, "FOR UPDATE")
  defp row_lock(query, :share), do: lock(query, "FOR SHARE")

  # An unknown permission is a programming error, not a denial.
  defp validate!(permission) when permission in @permissions, do: permission

  defp validate!(permission),
    do: raise(ArgumentError, "unknown permission #{inspect(permission)}")
end
