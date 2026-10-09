defmodule Renga.Findings do
  @moduledoc """
  Findings from every domain as one queue, and the workflow state people add
  to them (RFD 8, "Inbox").

  Reconciliation opens and closes findings in each domain's own table; this
  context never does. It reads the four finding tables through one query and
  lets people record judgment on top: an assignee, a snooze until a time, or
  an exception accepted with a reason and optional expiry. Snoozes and
  exceptions only move a finding out of the open queue while they last, so
  an expired exception returns the finding to the queue without anyone
  acting. Nothing here can make a finding disagree with observed reality.

  Workflow changes are open to owners, admins, and members, rechecked
  against the database in the transaction, and each one is recorded in
  Activity with its actor.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Catalog.ComponentFinding
  alias Renga.Catalog.HardwareMatchFinding
  alias Renga.DCIM.PlacementFinding
  alias Renga.Findings.Finding
  alias Renga.Findings.Workflow
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Topology.TopologyFinding

  @actor_roles ~w(owner admin member)
  @states ~w(open snoozed excepted resolved)
  @groups ~w(drift health)
  @per_page 50

  # Drift: what is observed differs from what is expected or planned. Every
  # other kind is a health finding: ambiguous, unknown, or conflicting
  # evidence that keeps Renga from knowing what is true.
  @drift_kinds %{
    "component" =>
      ~w(component_drift missing_expected_component unexpected_actual_component incompatible_module_type),
    "placement" => ~w(confirmed_placement_conflict catalog_height_mismatch blocked_move),
    "topology" =>
      ~w(missing_vlan unexpected_vlan cable_plan_drift cable_plan_conflict cable_neighbor_mismatch)
  }
  @drift_pairs for {domain, kinds} <- @drift_kinds, kind <- kinds, do: "#{domain}:#{kind}"

  def states, do: @states
  def groups, do: @groups

  @doc "The queue group, `\"drift\"` or `\"health\"`, for a finding kind."
  def group(domain, kind) do
    if "#{domain}:#{kind}" in @drift_pairs, do: "drift", else: "health"
  end

  @doc """
  UI hint: whether the scope may assign, snooze, or accept exceptions. The
  actions recheck membership themselves.
  """
  def can_change_workflow?(%Scope{user: %{}, roles: roles}),
    do: Enum.any?(roles || [], &(&1 in @actor_roles))

  def can_change_workflow?(_scope), do: false

  @doc "People a finding can be assigned to: active owners, admins, and members."
  def assignable_users(%Scope{} = scope) do
    scope
    |> Accounts.list_active_members(@actor_roles)
    |> Enum.map(& &1.user)
  end

  ## Reading

  @doc """
  Lists findings across domains, newest observation first.

  Options:

    * `:state` - `"open"` (default), `"snoozed"`, `"excepted"`, or `"resolved"`
    * `:group` - `"drift"` or `"health"`
    * `:assignee` - a user id, or `:unassigned`
    * `:resource_id` - one resource's findings
    * `:interface_id` - one interface's (topology) findings
    * `:domain` - one finding domain
    * `:kind` - one finding kind
    * `:page` - 1-based page of #{@per_page}

  Returns `{findings, total}`.
  """
  def list_findings(%Scope{} = scope, opts \\ []) do
    now = Renga.Time.utc_now_ms()
    query = scope |> filtered_query(opts, now)
    total = Repo.aggregate(query, :count)
    page = max(Keyword.get(opts, :page, 1), 1)

    findings =
      query
      |> order_by_group(Keyword.get(opts, :group))
      |> order_for(Keyword.get(opts, :state, "open"))
      |> limit(@per_page)
      |> offset(^((page - 1) * @per_page))
      |> select_finding()
      |> Repo.all()
      |> build_findings(now)

    {findings, total}
  end

  @doc "Page size used by `list_findings/2`."
  def per_page, do: @per_page

  @doc """
  Counts findings per queue group for the same filters as `list_findings/2`
  (ignoring `:group` and `:page`), so tabs can show totals.
  """
  def count_by_group(%Scope{} = scope, opts \\ []) do
    now = Renga.Time.utc_now_ms()
    opts = Keyword.drop(opts, [:group, :page])

    Map.new(@groups, fn group ->
      {group, scope |> filtered_query([{:group, group} | opts], now) |> Repo.aggregate(:count)}
    end)
  end

  @doc "Fetches one finding by domain and id inside the caller's organization."
  def get_finding!(%Scope{} = scope, domain, id),
    do: get_finding(scope, domain, id) || raise(Ecto.NoResultsError, queryable: Workflow)

  @doc """
  Like `get_finding!/3` but returns nil, including for a malformed domain or
  id, since both often come from a URL.
  """
  def get_finding(%Scope{} = scope, domain, id) do
    with true <- domain in Workflow.domains(),
         {:ok, id} <- Ecto.UUID.cast(id),
         row when not is_nil(row) <-
           scope
           |> base_query()
           |> where([finding: finding], finding.domain == ^domain and finding.id == ^id)
           |> select_finding()
           |> Repo.one() do
      [finding] = build_findings([row], Renga.Time.utc_now_ms())
      finding
    else
      _missing -> nil
    end
  end

  @doc """
  Exceptions in force on a resource, so everyone viewing the resource sees
  what was accepted and why.
  """
  def list_resource_exceptions(%Scope{} = scope, resource_id) do
    now = Renga.Time.utc_now_ms()

    scope
    |> base_query()
    |> where([finding: finding], finding.resource_id == ^resource_id)
    |> where(^state_filter("excepted", now))
    |> order_by([finding: finding], desc: finding.last_observed_at)
    |> select_finding()
    |> Repo.all()
    |> build_findings(now)
  end

  @doc "Workflow changes recorded for a finding's identity, newest first."
  def list_history(%Scope{organization_id: organization_id}, %Finding{workflow: %Workflow{} = w}) do
    ChangeEvent
    |> where([event], event.organization_id == ^organization_id)
    |> where([event], event.finding_workflow_id == ^w.id)
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> preload(:actor_user)
    |> Repo.all()
  end

  def list_history(%Scope{}, %Finding{}), do: []

  ## Workflow changes

  @doc "Assigns the finding to an active owner, admin, or member, or unassigns it with nil."
  def assign(%Scope{} = scope, %Finding{} = finding, assignee_user_id) do
    change_workflow(scope, finding, "finding_assigned", fn _finding, workflow, _now ->
      with :ok <- validate_assignee(scope, assignee_user_id) do
        {:ok, Workflow.assign_changeset(workflow, assignee_user_id)}
      end
    end)
  end

  @doc "Snoozes the finding until a future time, or wakes it with nil."
  def snooze(%Scope{} = scope, %Finding{} = finding, until) do
    change_workflow(scope, finding, "finding_snoozed", fn _finding, workflow, now ->
      {:ok, Workflow.snooze_changeset(workflow, until, now)}
    end)
  end

  @doc """
  Accepts the finding as an exception with `%{"exception_reason" => ...,
  "exception_expires_at" => ...}`. The reason is required; without an expiry
  the exception lasts until removed.
  """
  def accept_exception(%Scope{} = scope, %Finding{} = finding, attrs) do
    change_workflow(scope, finding, "finding_exception", fn _finding, workflow, now ->
      {:ok, Workflow.exception_changeset(workflow, attrs, scope.user.id, now)}
    end)
  end

  @doc """
  Accepts a missing expected component as out until a date (RFD 8, "Editing
  hardware components": "it is out temporarily").

  The gap is recorded on the workflow the missing-component finding will
  have, keyed by its `resolution_key`, so it applies whether or not a
  collector has already reported the slot missing: a finding that opens
  later arrives already excepted, and returns to the queue when the date
  passes. Unlike `accept_exception/3`, the date is required.
  """
  def accept_component_gap(
        %Scope{organization_id: organization_id} = scope,
        resource_id,
        resolution_key,
        attrs
      ) do
    Repo.transaction(fn ->
      authorize_actor!(scope)
      now = Renga.Time.utc_now_ms()
      resource = Inventory.get_resource!(scope, resource_id)

      finding = %Finding{
        domain: "component",
        id: nil,
        kind: "missing_expected_component",
        subject_id: resource.id,
        resolution_key: resolution_key,
        resource: resource
      }

      workflow = lock_workflow!(scope, finding)

      changeset =
        workflow
        |> Workflow.exception_changeset(attrs, scope.user.id, now)
        |> Ecto.Changeset.validate_required([:exception_expires_at],
          message: "choose when it will be back"
        )

      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _event} <- record(scope, finding, "finding_exception", workflow, updated, now) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc false
  # A hardware revision move renames the slots a resource's findings are
  # keyed by; their workflows (assignee, snooze, accepted gap) follow.
  # Runs inside the catalog's move transaction, which authorized the move.
  def rekey_component_workflows(organization_id, resource_id, key_map) do
    Enum.each(key_map, fn {old_key, new_key} ->
      Workflow
      |> where([workflow], workflow.organization_id == ^organization_id)
      |> where([workflow], workflow.domain == "component" and workflow.subject_id == ^resource_id)
      |> where([workflow], workflow.resolution_key == ^old_key)
      |> Repo.update_all(set: [resolution_key: new_key])
    end)
  end

  @doc """
  The component workflows of one resource that currently set a finding
  aside as an exception, keyed by `{kind, resolution_key}`. The Hardware tab
  uses them to show a slot that is out until a date.
  """
  def component_exceptions(%Scope{organization_id: organization_id}, resource_id) do
    now = Renga.Time.utc_now_ms()

    Workflow
    |> where(
      [workflow],
      workflow.organization_id == ^organization_id and workflow.domain == "component" and
        workflow.subject_id == ^resource_id and not is_nil(workflow.exception_at)
    )
    |> Repo.all()
    |> Enum.filter(&Workflow.excepted?(&1, now))
    |> Map.new(&{{&1.kind, &1.resolution_key}, &1})
  end

  @doc "Removes an accepted exception; the finding returns to the queue if still open."
  def remove_exception(%Scope{} = scope, %Finding{} = finding) do
    change_workflow(scope, finding, "finding_exception_removed", fn _finding, workflow, _now ->
      {:ok, Workflow.remove_exception_changeset(workflow)}
    end)
  end

  @doc "A blank changeset for the exception form."
  def change_exception(%Finding{workflow: workflow}, attrs \\ %{}) do
    (workflow || %Workflow{})
    |> Ecto.Changeset.cast(attrs, [:exception_reason, :exception_expires_at])
  end

  # The finding is re-read in the caller's organization inside the
  # transaction: the struct comes from the caller (and, in the UI, from a
  # client event), so neither its organization nor its status is trusted.
  defp change_workflow(%Scope{organization_id: organization_id} = scope, finding, kind, build) do
    Repo.transaction(fn ->
      authorize_actor!(scope)
      now = Renga.Time.utc_now_ms()
      finding = get_finding(scope, finding.domain, finding.id) || Repo.rollback(:not_found)
      # An old occurrence must never mutate the workflow of its recurrence.
      if finding.status != "open", do: Repo.rollback(:resolved)
      workflow = lock_workflow!(scope, finding)

      with {:ok, changeset} <- build.(finding, workflow, now),
           {:ok, updated} <- update_if_changed(changeset),
           {:ok, _event} <- record(scope, finding, kind, workflow, updated, now) do
        updated
      else
        :unchanged -> workflow
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  defp update_if_changed(%Ecto.Changeset{valid?: true, changes: changes}) when changes == %{},
    do: :unchanged

  defp update_if_changed(changeset), do: Repo.update(changeset)

  # Workflow rows are created on first use. The insert races safely with a
  # concurrent first use through the identity index, and the row is then
  # locked so two people's changes apply one after the other.
  defp lock_workflow!(%Scope{organization_id: organization_id}, %Finding{} = finding) do
    identity = [
      organization_id: organization_id,
      domain: finding.domain,
      subject_id: finding.subject_id,
      kind: finding.kind,
      resolution_key: finding.resolution_key
    ]

    %Workflow{resource_id: finding.resource.id}
    |> struct(identity)
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:organization_id, :domain, :subject_id, :kind, :resolution_key]
    )

    Workflow
    |> where(^identity)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp record(scope, finding, kind, before, after_, now) do
    Inventory.create_change_event(scope, %{
      kind: kind,
      field: "#{finding.domain}.#{finding.kind}",
      resource_id: finding.resource.id,
      finding_workflow_id: after_.id,
      old_value: audit_state(kind, before),
      new_value: audit_state(kind, after_),
      metadata: %{
        "finding_id" => finding.id,
        "domain" => finding.domain,
        "resolution_key" => finding.resolution_key,
        "interface_id" => finding.interface_id
      },
      occurred_at: now
    })
  end

  defp audit_state("finding_assigned", workflow) do
    case workflow.assignee_user_id do
      nil -> nil
      id -> %{"assignee_user_id" => id, "assignee" => user_email(id)}
    end
  end

  defp audit_state("finding_snoozed", %{snoozed_until: nil}), do: nil

  defp audit_state("finding_snoozed", %{snoozed_until: until}),
    do: %{"snoozed_until" => DateTime.to_iso8601(until)}

  defp audit_state(_exception, %{exception_reason: nil}), do: nil

  defp audit_state(_exception, workflow) do
    %{
      "reason" => workflow.exception_reason,
      "expires_at" =>
        workflow.exception_expires_at && DateTime.to_iso8601(workflow.exception_expires_at)
    }
  end

  defp user_email(id),
    do: Repo.one(from user in Accounts.User, where: user.id == ^id, select: user.email)

  defp validate_assignee(_scope, nil), do: :ok

  defp validate_assignee(%Scope{organization_id: organization_id}, user_id) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([membership], membership.user_id == ^user_id)
    |> where([membership], membership.status == "active" and membership.role in @actor_roles)
    |> Repo.exists?()
    |> if(do: :ok, else: {:error, :invalid_assignee})
  end

  defp authorize_actor!(%Scope{
         membership_id: membership_id,
         user: %{id: user_id},
         organization_id: organization_id
       })
       when not is_nil(membership_id) do
    active? =
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> where([organization], organization.status == "active")
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    member? =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.status == "active" and membership.role in @actor_roles)
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    unless active? and member?, do: Repo.rollback(:forbidden)
  end

  defp authorize_actor!(%Scope{}), do: Repo.rollback(:forbidden)

  ## Query building

  defp filtered_query(scope, opts, now) do
    scope
    |> base_query()
    |> where(^state_filter(Keyword.get(opts, :state, "open"), now))
    |> filter_group(Keyword.get(opts, :group))
    |> filter_assignee(Keyword.get(opts, :assignee))
    |> filter_resource(Keyword.get(opts, :resource_id))
    |> filter_domain(Keyword.get(opts, :domain))
    |> filter_interface(Keyword.get(opts, :interface_id))
    |> filter_kind(Keyword.get(opts, :kind))
  end

  defp base_query(%Scope{organization_id: organization_id}) do
    from finding in subquery(findings_union(organization_id)),
      as: :finding,
      join: resource in Resource,
      as: :resource,
      on: resource.id == finding.resource_id and resource.organization_id == ^organization_id,
      left_join: interface in Interface,
      as: :interface,
      on: interface.id == finding.interface_id,
      left_join: workflow in Workflow,
      as: :workflow,
      on:
        workflow.organization_id == ^organization_id and workflow.domain == finding.domain and
          workflow.subject_id == finding.subject_id and workflow.kind == finding.kind and
          workflow.resolution_key == finding.resolution_key
  end

  # The four finding tables in one shape. Topology findings belong to an
  # interface; their resource is the interface's resource.
  defp findings_union(organization_id) do
    component =
      from finding in ComponentFinding,
        where: finding.organization_id == ^organization_id,
        select: %{
          domain: type(^"component", :string),
          id: finding.id,
          resource_id: finding.resource_id,
          subject_id: finding.resource_id,
          interface_id: type(^nil, :binary_id),
          kind: finding.kind,
          resolution_key: finding.resolution_key,
          status: finding.status,
          message: finding.message,
          details: finding.details,
          opened_at: finding.inserted_at,
          last_observed_at: finding.last_observed_at,
          resolved_at: finding.resolved_at
        }

    hardware_match =
      from finding in HardwareMatchFinding,
        where: finding.organization_id == ^organization_id,
        select: %{
          domain: type(^"hardware_match", :string),
          id: finding.id,
          resource_id: finding.resource_id,
          subject_id: finding.resource_id,
          interface_id: type(^nil, :binary_id),
          kind: finding.kind,
          resolution_key: type(^"", :string),
          status: finding.status,
          message: finding.message,
          details: finding.details,
          opened_at: finding.inserted_at,
          last_observed_at: finding.updated_at,
          resolved_at: finding.resolved_at
        }

    placement =
      from finding in PlacementFinding,
        where: finding.organization_id == ^organization_id,
        select: %{
          domain: type(^"placement", :string),
          id: finding.id,
          resource_id: finding.resource_id,
          subject_id: finding.resource_id,
          interface_id: type(^nil, :binary_id),
          kind: finding.kind,
          resolution_key: type(^"", :string),
          status: finding.status,
          message: finding.message,
          details: finding.details,
          opened_at: finding.inserted_at,
          last_observed_at: finding.updated_at,
          resolved_at: finding.resolved_at
        }

    topology =
      from finding in TopologyFinding,
        join: interface in Interface,
        on:
          interface.id == finding.interface_id and interface.organization_id == ^organization_id,
        where: finding.organization_id == ^organization_id,
        select: %{
          domain: type(^"topology", :string),
          id: finding.id,
          resource_id: interface.resource_id,
          subject_id: finding.interface_id,
          interface_id: finding.interface_id,
          kind: finding.kind,
          resolution_key: finding.resolution_key,
          status: finding.status,
          message: finding.message,
          details: finding.details,
          opened_at: finding.inserted_at,
          last_observed_at: finding.last_observed_at,
          resolved_at: finding.resolved_at
        }

    component
    |> union_all(^hardware_match)
    |> union_all(^placement)
    |> union_all(^topology)
  end

  defp state_filter("snoozed", now) do
    dynamic(
      [finding: finding],
      finding.status == "open" and not (^excepted(now)) and ^snoozed(now)
    )
  end

  defp state_filter("excepted", now),
    do: dynamic([finding: finding], finding.status == "open" and ^excepted(now))

  defp state_filter("resolved", _now),
    do: dynamic([finding: finding], finding.status == "resolved")

  defp state_filter(_open, now) do
    dynamic(
      [finding: finding],
      finding.status == "open" and not (^excepted(now)) and not (^snoozed(now))
    )
  end

  defp excepted(now) do
    dynamic(
      [workflow: workflow],
      not is_nil(workflow.exception_at) and
        (is_nil(workflow.exception_expires_at) or workflow.exception_expires_at > ^now)
    )
  end

  defp snoozed(now),
    do:
      dynamic(
        [workflow: workflow],
        fragment("coalesce(? > ?, false)", workflow.snoozed_until, ^now)
      )

  defp filter_group(query, "drift"), do: where(query, ^drift())
  defp filter_group(query, "health"), do: where(query, ^dynamic(not (^drift())))
  defp filter_group(query, _group), do: query

  defp drift do
    dynamic(
      [finding: finding],
      fragment(
        "? || ':' || ? = ANY(?)",
        finding.domain,
        finding.kind,
        type(^@drift_pairs, {:array, :string})
      )
    )
  end

  defp filter_assignee(query, nil), do: query

  defp filter_assignee(query, :unassigned),
    do: where(query, [workflow: workflow], is_nil(workflow.assignee_user_id))

  defp filter_assignee(query, user_id),
    do: where(query, [workflow: workflow], workflow.assignee_user_id == ^user_id)

  defp filter_resource(query, nil), do: query

  defp filter_resource(query, resource_id),
    do: where(query, [finding: finding], finding.resource_id == ^resource_id)

  defp filter_interface(query, nil), do: query

  defp filter_interface(query, interface_id),
    do: where(query, [finding: finding], finding.interface_id == ^interface_id)

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [finding: finding], finding.kind == ^kind)

  defp filter_domain(query, nil), do: query

  defp filter_domain(query, domain),
    do: where(query, [finding: finding], finding.domain == ^domain)

  # Without a group filter the queue lists drift before health, the order
  # RFD 8 groups the Inbox in, so group headers can be drawn over one page.
  defp order_by_group(query, nil), do: order_by(query, ^[desc: drift()])
  defp order_by_group(query, _group), do: query

  defp order_for(query, "resolved"),
    do: order_by(query, [finding: finding], desc: finding.resolved_at, desc: finding.id)

  defp order_for(query, _state),
    do: order_by(query, [finding: finding], desc: finding.last_observed_at, desc: finding.id)

  defp select_finding(query) do
    select(
      query,
      [finding: finding, resource: resource, interface: interface, workflow: workflow],
      %{
        finding: finding,
        resource: resource,
        interface_name: interface.name,
        workflow: workflow
      }
    )
  end

  defp build_findings(rows, now) do
    workflows =
      rows
      |> Enum.map(& &1.workflow)
      |> Enum.reject(&is_nil/1)
      |> Repo.preload([:assignee_user, :exception_by_user])
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn %{finding: row, workflow: workflow} = result ->
      workflow = workflow && Map.fetch!(workflows, workflow.id)

      %Finding{
        domain: row.domain,
        id: row.id,
        kind: row.kind,
        group: group(row.domain, row.kind),
        state: state(row.status, workflow, now),
        status: row.status,
        message: row.message,
        details: row.details,
        resolution_key: row.resolution_key,
        subject_id: row.subject_id,
        resource: result.resource,
        interface_id: row.interface_id,
        interface_name: result.interface_name,
        workflow: workflow,
        opened_at: row.opened_at,
        last_observed_at: row.last_observed_at,
        resolved_at: row.resolved_at
      }
    end)
  end

  defp state("resolved", _workflow, _now), do: :resolved

  defp state(_open, workflow, now) do
    cond do
      Workflow.excepted?(workflow, now) -> :excepted
      Workflow.snoozed?(workflow, now) -> :snoozed
      true -> :open
    end
  end
end
