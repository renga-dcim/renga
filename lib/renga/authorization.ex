defmodule Renga.Authorization do
  @moduledoc """
  The single place that answers "may this scope do this?" (RFD 17).

  A permission names one kind of action, such as `"inventory.edit"`. The
  catalogue is defined here, in code; organizations cannot add to it. A role
  is a named set of permissions: one of the four built-in roles, which
  reproduce the behavior of the role lists the contexts used to check, or a
  custom role an organization defines (`Renga.Roles`). Every membership holds
  a built-in base role, and assignments (`Renga.Assignments`) add further
  roles until they expire. What a person may do is the union of all of them.

  Two entry points answer the question:

    * `allowed?/3` reads the roles cached in the scope. It is a UI hint and
      never a boundary.
    * `authorize!/3` runs inside the context transaction that performs the
      change. It locks the organization (which must be active) and then the
      membership, re-reading the base role and current assignments from the
      database, and rolls the transaction back with `:forbidden` when the
      permission is missing.
      Every context takes those two locks in that order so concurrent
      mutations cannot deadlock.

  Machine work (agents' reconcilers, triage rule application) runs as fixed
  internal principals instead of people. They hold no catalogue permissions
  and are checked with `authorize_system!/2`, so a principal can only run the
  paths that name it.

  Conditions arrive later; until then every grant covers the whole
  organization, so `allowed?/3` accepts a target but does not consult it.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMFA
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Repo
  alias Renga.Roles.Assignment

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
    "queries.run",
    "queries.run_sensitive",
    "views.share",
    "teams.manage",
    "groups.manage",
    "triage_rules.manage",
    "intake_keys.manage",
    "members.manage",
    "roles.manage",
    "organization.manage",
    "organization.export",
    "scim.manage"
  ]

  @descriptions %{
    "inventory.read" => "See resources and what they report",
    "inventory.reconcile" => "Reconcile observations and accept reconciliation results",
    "inventory.edit" => "Change lifecycle, set field overrides, and edit managed kinds",
    "findings.act" => "Assign, snooze, and accept exceptions on findings",
    "requests.create" => "Propose changes they cannot make directly",
    "requests.decide" => "Approve or reject proposed changes",
    "catalog.author" => "Edit catalog types, drafts, modules, and inventory items",
    "catalog.expectations" => "Change what a resource expects and automatic moves",
    "dcim.edit" => "Edit sites, locations, racks, and placement",
    "ipam.edit" => "Edit VRFs, prefixes, addresses, plans, and source mappings",
    "topology.edit" => "Edit VLANs, cables, cable plans, and import contracts",
    "jobs.request" => "Request, cancel, and resolve observe jobs other than queries",
    "queries.run" => "Run operational queries and read their results",
    "queries.run_sensitive" => "With queries.run, run sensitive queries and read their results",
    "views.share" => "Save and change views shared with the organization",
    "teams.manage" => "Manage teams, who is on them, and resource owners",
    "groups.manage" => "Define resource groups and group sets",
    "triage_rules.manage" => "Manage triage rules",
    "intake_keys.manage" => "Manage intake API keys",
    "members.manage" => "Invite and disable members and change their roles",
    "roles.manage" => "Define custom roles",
    "organization.manage" => "Change organization settings",
    "organization.export" => "Export the whole organization",
    "scim.manage" => "Connect SCIM provisioning and manage its tokens and role mappings"
  }

  @workflow ~w(inventory.reconcile findings.act catalog.author)
  @management ~w(inventory.edit requests.decide catalog.expectations dcim.edit ipam.edit
                 topology.edit jobs.request views.share teams.manage groups.manage triage_rules.manage
                 intake_keys.manage members.manage roles.manage)
  @organization ~w(organization.manage organization.export scim.manage)
  # A SCIM connection's mappings can grant any built-in role, so like
  # members.manage it never rides on a custom role.
  @reserved ~w(members.manage roles.manage scim.manage)

  # Explicit permissions open operational access to hosts. No built-in role
  # includes them and nobody holds them by default, owners included: a
  # built-in owner or admin issues them, to anyone including themselves,
  # through a custom role that carries nothing else, so a routine role never
  # quietly acquires them.
  @explicit ~w(queries.run queries.run_sensitive)

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

  @doc """
  The explicit permissions: in no built-in role, issued only through custom
  roles that carry no other permission.
  """
  def explicit_permissions, do: @explicit

  @doc "Whether `permission` is explicit."
  def explicit?(permission), do: validate!(permission) in @explicit

  @doc "What `permission` allows, in a phrase for people."
  def describe(permission), do: Map.fetch!(@descriptions, validate!(permission))

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

  @doc """
  The built-in roles a holder of `role` may grant, change, or take away
  (RFD 17's grant ceiling), most privileged first.

  The ceiling is separate from action permissions: an admin may grant
  `member`, and with it `requests.create`, without holding it. Only an owner
  may grant `owner`, and so the owner-only organization permissions.
  """
  def grantable_roles(roles) when is_list(roles) do
    grantable = Enum.flat_map(roles, &grantable_roles/1)
    Enum.filter(@role_order, &(&1 in grantable))
  end

  def grantable_roles("owner"), do: @role_order
  def grantable_roles("admin"), do: ~w(admin member viewer)
  def grantable_roles(_role), do: []

  @doc """
  The permissions a custom role may carry. `members.manage`,
  `roles.manage`, and `scim.manage` are reserved to the built-in roles.
  """
  def custom_role_permissions, do: @permissions -- @reserved

  @doc """
  The permissions a holder of built-in `role` may put in a custom role or
  grant (RFD 17's grant ceiling). Only owners may grant the owner-only
  organization permissions. Owners and admins may both issue the explicit
  permissions without holding them, which is how an organization where
  nobody holds one gets its first holder.
  """
  def grantable_permissions(roles) when is_list(roles) do
    grantable = Enum.flat_map(roles, &grantable_permissions/1)
    Enum.filter(custom_role_permissions(), &(&1 in grantable))
  end

  def grantable_permissions("owner"), do: custom_role_permissions()
  def grantable_permissions("admin"), do: custom_role_permissions() -- @organization
  def grantable_permissions(_role), do: []

  @doc "The fixed internal principals machine scopes run as."
  def machine_principals, do: @machine_principals

  @doc """
  Whether the scope's cached roles and assigned permissions grant
  `permission`.

  Only people hold permissions; a machine scope is never allowed. Use this for
  UI hints only: the transaction check in `authorize!/3` is authoritative.
  """
  def allowed?(scope, permission, target \\ nil)

  def allowed?(%Scope{user: %{}, roles: roles, permissions: permissions}, permission, _target) do
    granting = roles_granting(permission)
    Enum.any?(roles || [], &(&1 in granting)) or permission in (permissions || [])
  end

  def allowed?(_scope, permission, _target) do
    validate!(permission)
    false
  end

  @doc """
  Which of `permissions` the scope's membership holds now, read from the
  database rather than the scope's cache, without locks.

  For read paths that disclose a payload only to current holders, such as
  query results (RFD 12): a revoked assignment stops disclosure on the next
  read even while a connected page still carries the old scope. A machine
  scope, or a disabled membership or inactive organization, holds none.
  """
  def held_now(scope, permissions)

  def held_now(
        %Scope{membership_id: membership_id, user: %{id: user_id}} = scope,
        permissions
      )
      when not is_nil(membership_id) do
    Enum.each(permissions, &validate!/1)

    active? =
      Organization
      |> where([organization], organization.id == ^scope.organization_id)
      |> where([organization], organization.status == "active")
      |> Repo.exists?()

    membership =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^scope.organization_id)
      |> where([membership], membership.status == "active")

    if active?,
      do: Enum.filter(permissions, &(membership |> holding(&1) |> Repo.exists?())),
      else: []
  end

  def held_now(_scope, permissions) do
    Enum.each(permissions, &validate!/1)
    []
  end

  @doc """
  Requires `permission` inside the current transaction.

  Locks the scope's organization, requiring it to be active, then the
  scope's own active membership, and checks the membership's current base
  role and assignments. Rolls the transaction back with `:forbidden`
  otherwise.

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
    mode = Keyword.get(opts, :lock, :update)
    lock_active_organization!(scope.organization_id, mode)

    OrganizationMembership
    |> where([membership], membership.id == ^membership_id)
    |> where([membership], membership.user_id == ^user_id)
    |> where([membership], membership.organization_id == ^scope.organization_id)
    |> where([membership], membership.status == "active")
    |> holding(permission)
    |> select([membership], membership.id)
    |> row_lock(mode)
    |> Repo.one()
    |> case do
      nil ->
        Repo.rollback(:forbidden)

      _membership_id ->
        if OrganizationMFA.satisfied?(scope.user, scope.organization_id),
          do: :ok,
          else: Repo.rollback(:forbidden)
    end
  end

  def authorize!(%Scope{}, permission, _opts) do
    validate!(permission)
    Repo.rollback(:forbidden)
  end

  @doc """
  Narrows an `OrganizationMembership` query to memberships whose base role
  or a current assignment grants `permission`. It does not check status.
  For `authorize!/3` and for pickers that choose people by what they may
  do, such as a finding's assignee.
  """
  def holding(query, permission) do
    granting = roles_granting(permission)
    now = Renga.Time.utc_now_ms()

    holders =
      from assignment in current_assignments(now),
        left_join: role in assoc(assignment, :role),
        where:
          assignment.built_in_role in ^granting or
            fragment("? = ANY(?)", ^permission, role.permissions),
        select: assignment.membership_id

    where(
      query,
      [membership],
      membership.role in ^granting or membership.id in subquery(holders)
    )
  end

  @doc """
  The built-in roles the scope's membership holds now: its base role and
  current built-in assignments. Call it after `authorize!/3` in the same
  transaction, which holds the membership's lock, to bound what the actor
  may grant by their current roles rather than those cached in the scope.
  Custom roles never raise the ceiling.
  """
  def current_roles!(%Scope{membership_id: membership_id}) when not is_nil(membership_id),
    do: current_roles!(membership_id)

  def current_roles!(membership_id) when is_binary(membership_id) do
    base =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> select([membership], membership.role)
      |> Repo.one!()

    {assigned, _permissions} = assigned_access(membership_id)
    Enum.uniq([base | assigned])
  end

  @doc """
  What a membership's current assignments add to its base role: the
  built-in roles they give, and the permissions of the custom roles they
  give. For building a scope.
  """
  def assigned_access(membership_id) do
    Renga.Time.utc_now_ms()
    |> current_assignments()
    |> where([assignment], assignment.membership_id == ^membership_id)
    |> join(:left, [assignment], role in assoc(assignment, :role))
    |> select([assignment, role], {assignment.built_in_role, role.permissions})
    |> Repo.all()
    |> Enum.reduce({[], []}, fn
      {nil, permissions}, {roles, acc} -> {roles, acc ++ permissions}
      {role, nil}, {roles, acc} -> {[role | roles], acc}
    end)
    |> then(fn {roles, permissions} ->
      {Enum.uniq(roles), permissions |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp current_assignments(now) do
    from assignment in Assignment,
      where: is_nil(assignment.valid_until) or assignment.valid_until > ^now
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
