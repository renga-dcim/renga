defmodule Renga.AuthorizationParityTest do
  @moduledoc """
  Pins who may pass each context's authorization gate (RFD 17).

  Each case calls one public mutation behind a distinct gate as every
  built-in role and every machine principal. The expected roles are written
  out literally, as the role lists the contexts checked before permissions
  existed, so moving a context onto `Renga.Authorization` cannot quietly
  change who may act. A call that gets past the gate may still fail for
  other reasons (a bogus ID, invalid attributes); only `{:error,
  :forbidden}` counts as refused.
  """
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Catalog
  alias Renga.DCIM
  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.IPAM
  alias Renga.Jobs
  alias Renga.Requests
  alias Renga.ResourceGroups
  alias Renga.SavedViews
  alias Renga.Teams
  alias Renga.Topology
  alias Renga.TriageRules

  @managers ~w(owner admin)
  @workers ~w(owner admin member)

  # {gate, roles that pass it, the machine principal that passes it (`:any`
  # for organization-scoped agent paths that take no principal), call}
  @cases [
    {"inventory lifecycle", @managers, nil, &__MODULE__.update_lifecycle/2},
    {"intake keys", @managers, nil, &__MODULE__.create_intake_key/2},
    {"inventory reconciliation", @workers, :any, &__MODULE__.reconcile_observation/2},
    {"ipam", @managers, nil, &__MODULE__.create_vrf/2},
    {"dcim", @managers, nil, &__MODULE__.create_site/2},
    {"dcim reconciliation", @managers, "placement_reconciler", &__MODULE__.reconcile_placement/2},
    {"topology", @managers, nil, &__MODULE__.create_vlan_group/2},
    {"topology reconciliation", @workers, "topology_reconciler", &__MODULE__.reconcile_cables/2},
    {"catalog", @workers, nil, &__MODULE__.create_manufacturer/2},
    {"catalog expectations", @managers, nil, &__MODULE__.put_expectation_exception/2},
    {"catalog reconciliation", @workers, "catalog_reconciler",
     &__MODULE__.reconcile_hardware_type/2},
    {"findings", @workers, nil, &__MODULE__.accept_component_gap/2},
    {"requests create", ~w(member), nil, &__MODULE__.request_lifecycle/2},
    {"requests decide", @managers, nil, &__MODULE__.approve_requests/2},
    {"requests reject", @managers, nil, &__MODULE__.reject_request/2},
    {"jobs cancel", @managers, nil, &__MODULE__.cancel_job/2},
    {"jobs resolve", @managers, nil, &__MODULE__.resolve_job/2},
    {"job settings", ~w(owner), nil, &__MODULE__.update_job_settings/2},
    {"default accent", ~w(owner), nil, &__MODULE__.set_default_accent/2},
    {"teams", @managers, nil, &__MODULE__.create_team/2},
    {"resource groups", @managers, nil, &__MODULE__.create_resource_group/2},
    {"resource group membership", @managers, nil, &__MODULE__.add_group_members/2},
    {"triage rules", @managers, "triage_rules", &__MODULE__.create_triage_rule/2},
    {"shared views", @managers, nil, &__MODULE__.share_view/2}
  ]

  # {hint, roles it shows controls to}
  @hints [
    {&Inventory.collector_manager?/1, @managers},
    {&Catalog.catalog_author?/1, @workers},
    {&Catalog.can_change_expectations?/1, @managers},
    {&Findings.can_change_workflow?/1, @workers},
    {&Requests.can_request?/1, ~w(member)},
    {&Requests.can_decide?/1, @managers},
    {&Teams.can_manage?/1, @managers},
    {&ResourceGroups.can_manage?/1, @managers},
    {&ResourceGroups.can_change_membership?/1, @managers},
    {&TriageRules.can_manage?/1, @managers}
  ]

  setup do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")

    {:ok, resource} =
      Inventory.create_resource(owner, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    people = Map.new(Authorization.built_in_roles(), &{&1, member_scope(organization, &1)})

    machines =
      Map.new(Authorization.machine_principals(), fn principal ->
        {principal,
         %Scope{organization: organization, organization_id: organization.id, roles: [principal]}}
      end)

    %{organization: organization, resource: resource, people: people, machines: machines}
  end

  for {gate, roles, principal, call} <- @cases do
    @gate gate
    @roles roles
    @principal principal
    @call call

    test "#{gate}: built-in roles keep their access", context do
      for {role, scope} <- context.people do
        expected = if role in @roles, do: :allowed, else: :forbidden

        assert outcome(@call, scope, context) == expected,
               "#{@gate}: #{role} should be #{expected}"
      end
    end

    test "#{gate}: only its own machine principal passes", context do
      for {principal, scope} <- context.machines do
        expected = if @principal in [:any, principal], do: :allowed, else: :forbidden

        assert outcome(@call, scope, context) == expected,
               "#{@gate}: #{principal} should be #{expected}"
      end
    end
  end

  test "UI hints follow the same roles", context do
    for {hint, roles} <- @hints, {role, scope} <- context.people do
      assert hint.(scope) == role in roles, "#{inspect(hint)} for #{role}"
    end

    for {hint, _roles} <- @hints, {_principal, scope} <- context.machines do
      refute hint.(scope), "#{inspect(hint)} for a machine scope"
    end
  end

  defp outcome(call, scope, context) do
    case call.(scope, context) do
      {:error, :forbidden} -> :forbidden
      _passed_the_gate -> :allowed
    end
  rescue
    # Raised after the gate, by the deliberately bogus target.
    _error -> :allowed
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def update_lifecycle(scope, context),
    do: Inventory.update_resource_lifecycle(scope, context.resource, "inactive")

  def create_intake_key(scope, _context),
    do: Inventory.create_intake_api_key(scope, %{name: unique("key")})

  def reconcile_observation(scope, _context),
    do: Inventory.reconcile_observation(scope, Ecto.UUID.generate())

  def create_vrf(scope, _context), do: IPAM.create_vrf(scope, %{name: unique("vrf")})

  def create_site(scope, _context), do: DCIM.create_site(scope, %{name: unique("site")}, %{})

  def reconcile_placement(scope, context),
    do: DCIM.reconcile_placement_evidence(scope, context.resource.id)

  def create_vlan_group(scope, _context),
    do: Topology.create_vlan_group(scope, %{name: unique("group")}, %{}, [])

  def reconcile_cables(scope, _context), do: Topology.reconcile_cables(scope)

  def create_manufacturer(scope, _context),
    do: Catalog.create_manufacturer(scope, %{name: unique("maker")}, %{})

  def put_expectation_exception(scope, context),
    do: Catalog.put_expected_component_exception(scope, context.resource.id, %{})

  def reconcile_hardware_type(scope, context),
    do: Catalog.reconcile_hardware_type(scope, context.resource.id)

  def accept_component_gap(scope, context),
    do: Findings.accept_component_gap(scope, context.resource.id, "cpu:0", %{})

  def request_lifecycle(scope, context) do
    Requests.request_lifecycle(scope, context.resource, %{
      "value" => "retired",
      "reason" => "parity"
    })
  end

  def approve_requests(scope, _context), do: Requests.approve(scope, [])

  def reject_request(scope, context) do
    Requests.reject(scope, %Requests.Request{
      id: Ecto.UUID.generate(),
      organization_id: context.organization.id
    })
  end

  def cancel_job(scope, _context), do: Jobs.cancel_job(scope, Ecto.UUID.generate())

  def resolve_job(scope, _context),
    do: Jobs.resolve_job(scope, Ecto.UUID.generate(), "failed")

  def create_resource_group(scope, _context),
    do: ResourceGroups.create_group(scope, %{name: unique("group")})

  def add_group_members(scope, context) do
    ResourceGroups.add_members(
      scope,
      %ResourceGroups.Group{id: Ecto.UUID.generate()},
      [context.resource.id]
    )
  end

  def update_job_settings(scope, _context), do: Jobs.update_settings(scope, %{})

  def set_default_accent(scope, _context), do: Accounts.set_default_accent(scope, "copper")

  def create_team(scope, _context), do: Teams.create_team(scope, %{"name" => unique("team")})

  def create_triage_rule(scope, _context), do: TriageRules.create_rule(scope, %{})

  def share_view(scope, _context),
    do: SavedViews.create_view(scope, %{shared: true, name: unique("view"), area: "resources"})
end
