defmodule Renga.TriageRules do
  @moduledoc """
  Triage rules (RFD 8, "Triage"): strong signals that fill the facts triage
  asks for, so people only triage what no rule can answer.

  Rules only ever fill a missing fact. A resource that already has a
  placement or an owner, from a person, a collector, or another rule, keeps
  it, so a rule can never undo what a person chose. Rules never pick a rack
  unit: the closest they get is a rack.

  Every fact a rule sets says so. Owners point back at the rule through
  `owner_rule_id`; placements carry the rule in their provenance and stay
  unconfirmed; and each one is an Activity entry naming the rule.

  A rule applies when it is saved (to everything it matches right now) and
  again whenever a collector reports a resource, so new discoveries get
  their facts without anyone re-running it. Before saving, `preview/2` says
  what the rule would change and what it would leave alone.

  Owners and admins manage rules. Applying rules after reconciliation runs
  as the system, with no user.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.DCIM
  alias Renga.DCIM.CurrentPlacement
  alias Renga.DCIM.Location
  alias Renga.DCIM.Site
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Host
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Teams.Team
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Triage
  alias Renga.TriageRules.Rule
  alias Renga.Types.Inet

  # The system role that applies rules after reconciliation.
  @system_role "triage_rules"
  @preview_examples 5
  @preloads [:team, :intake_api_key, site: :resource, location: :resource]

  # A placement from a person is confirmed; collectors and rules leave theirs
  # unconfirmed.
  defmacrop placement_state(placement) do
    quote do
      fragment(
        "CASE WHEN ? IS NULL THEN 'will_set' WHEN ? THEN 'set_by_person' ELSE 'has_value' END",
        unquote(placement).id,
        unquote(placement).confirmed
      )
    end
  end

  @doc "UI hint: owners and admins manage triage rules."
  def can_manage?(%Scope{} = scope), do: Inventory.organization_manager?(scope)

  @doc "The fact a rule kind sets."
  def fact(%Rule{kind: "ownership"}), do: :owner
  def fact(%Rule{}), do: :placement

  ## Rules

  @doc "The organization's rules by kind, then name, with what they reference."
  def list_rules(%Scope{organization_id: organization_id}) do
    Rule
    |> where([rule], rule.organization_id == ^organization_id)
    |> order_by([rule], asc: rule.kind, asc: fragment("lower(?)", rule.name))
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc "Fetches a rule in the caller's organization, or nil (ids often come from a URL)."
  def get_rule(%Scope{organization_id: organization_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id || ""),
         %Rule{} = rule <- Repo.get_by(Rule, id: id, organization_id: organization_id) do
      Repo.preload(rule, @preloads)
    else
      _missing -> nil
    end
  end

  @doc "A changeset for the rule form."
  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  @doc """
  What a rule would do if saved now, without saving it: how many resources
  it would give the fact, how many already have it from a collector or
  another rule, and how many have it from a person. Also lists a few
  resources it would change.

  Returns `{:ok, preview}` or `{:error, changeset}` when the rule is not
  complete yet.
  """
  def preview(%Scope{organization_id: organization_id} = scope, attrs) do
    %Rule{organization_id: organization_id}
    |> Rule.changeset(attrs)
    |> validate_references(scope)
    |> Ecto.Changeset.apply_action(:preview)
    |> case do
      {:ok, rule} -> {:ok, summarize(scope, rule)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates a rule and applies it to everything it matches. Owners and
  admins only. Returns `{:ok, %{rule: rule, applied: count}}`.
  """
  def create_rule(%Scope{organization_id: organization_id} = scope, attrs) do
    managed(scope, fn ->
      %Rule{
        organization_id: organization_id,
        created_by_user_id: scope.user.id
      }
      |> Rule.changeset(attrs)
      |> validate_references(scope)
      |> Repo.insert()
      |> apply_saved(scope)
    end)
  end

  @doc """
  Changes a rule and applies it again. Facts it set before stay, even when
  the rule no longer matches them. Owners and admins only.
  """
  def update_rule(%Scope{} = scope, %Rule{} = rule, attrs) do
    managed(scope, fn ->
      scope
      |> lock_rule!(rule.id)
      |> Rule.changeset(attrs)
      |> validate_references(scope)
      |> Repo.update()
      |> apply_saved(scope)
    end)
  end

  @doc """
  Turns a rule on, applying it to everything it matches, or off. A rule
  that is off keeps the facts it already set. Owners and admins only.
  """
  def set_enabled(%Scope{} = scope, %Rule{} = rule, enabled) when is_boolean(enabled) do
    managed(scope, fn ->
      scope
      |> lock_rule!(rule.id)
      |> Rule.enabled_changeset(enabled)
      |> Repo.update()
      |> apply_saved(scope)
    end)
  end

  @doc """
  Deletes a rule. The facts it set stay, still marked as set by a rule.
  Owners and admins only.
  """
  def delete_rule(%Scope{} = scope, %Rule{} = rule) do
    managed(scope, fn ->
      scope
      |> lock_rule!(rule.id)
      |> Repo.delete()
    end)
  end

  @doc """
  Applies every enabled rule to one resource, after a collector reported
  it. Runs as the system; rules apply in the order they were created, so
  when two rules could set the same fact the older one does.

  Never fails the report: returns the number of facts set, or
  `{:error, reason}`.
  """
  def apply_to_resource(organization_id, resource_id) do
    scope = %Scope{organization_id: organization_id, roles: [@system_role]}

    if enabled_rules?(organization_id),
      do: transaction(scope, fn -> {:ok, apply_enabled_rules(scope, resource_id)} end),
      else: {:ok, 0}
  end

  defp apply_enabled_rules(scope, resource_id) do
    scope.organization_id
    |> enabled_rules()
    |> Enum.map(&apply_rule(scope, &1, resource_id: resource_id))
    |> Enum.sum()
  end

  ## Matching

  # Resources a rule matches, each with the state of the fact it sets:
  # "will_set" (missing), "has_value" (set by a collector or another rule),
  # or "set_by_person". Top of rack matches also carry the rack.
  defp match_query(%Scope{organization_id: organization_id}, %Rule{} = rule) do
    from(resource in Resource,
      as: :resource,
      where: resource.organization_id == ^organization_id,
      where: resource.kind in ^subject_kinds(rule),
      where: resource.lifecycle_state != "retired",
      left_join: placement in CurrentPlacement,
      as: :placement,
      on: placement.resource_id == resource.id and placement.organization_id == ^organization_id
    )
    |> where_matches(organization_id, rule)
    |> select_state(rule)
  end

  # A switch's LLDP neighbor is usually another switch upstream, not the
  # rack it sits in, so top of rack never places switches.
  defp subject_kinds(%Rule{kind: "top_of_rack"}), do: Triage.kinds() -- ["switch"]
  defp subject_kinds(%Rule{}), do: Triage.kinds()

  defp where_matches(query, organization_id, %Rule{kind: "network_location", subnet: subnet})
       when not is_nil(subnet) do
    addresses =
      from address in Address,
        where:
          address.organization_id == ^organization_id and
            address.resource_id == parent_as(:resource).id and
            fragment("host(?)::inet <<= ?", address.address, type(^subnet, Inet))

    reported =
      from report in subquery(latest_reports(organization_id)),
        where: fragment("host(?)::inet <<= ?", report.reported_from, type(^subnet, Inet)),
        select: report.resource_id

    where(query, [resource], exists(addresses) or resource.id in subquery(reported))
  end

  defp where_matches(query, organization_id, %Rule{kind: "network_location"} = rule) do
    key_id = rule.intake_api_key_id

    reported =
      from report in subquery(latest_reports(organization_id)),
        where: report.intake_api_key_id == ^key_id,
        select: report.resource_id

    where(query, [resource], resource.id in subquery(reported))
  end

  defp where_matches(query, organization_id, %Rule{kind: "top_of_rack"}) do
    join(query, :inner, [resource], neighbor in subquery(neighbor_racks(organization_id)),
      as: :neighbor,
      on: neighbor.resource_id == resource.id
    )
  end

  defp where_matches(query, organization_id, %Rule{kind: "ownership", hostname_pattern: pattern})
       when is_binary(pattern) do
    like = glob_to_like(pattern)

    hosts =
      from host in Host,
        where:
          host.organization_id == ^organization_id and
            host.resource_id == parent_as(:resource).id and
            (like(host.hostname, ^like) or like(host.fqdn, ^like))

    where(query, [resource], exists(hosts))
  end

  defp where_matches(query, organization_id, %Rule{kind: "ownership"} = rule) do
    key = rule.label_key
    value = rule.label_value

    labelled =
      from report in subquery(latest_reports(organization_id)),
        where: fragment("?->'resources'->0->'labels'->>? = ?", report.payload, ^key, ^value),
        select: report.resource_id

    where(query, [resource], resource.id in subquery(labelled))
  end

  defp select_state(query, %Rule{kind: "ownership"}) do
    select(query, [resource], %{
      id: resource.id,
      name: resource.name,
      kind: resource.kind,
      rack_id: type(^nil, :binary_id),
      state:
        fragment(
          "CASE WHEN ? IS NULL THEN 'will_set' WHEN ? = 'person' THEN 'set_by_person' ELSE 'has_value' END",
          resource.owner_team_id,
          resource.owner_source
        )
    })
  end

  defp select_state(query, %Rule{kind: "top_of_rack"}) do
    select(query, [resource, placement: placement, neighbor: neighbor], %{
      id: resource.id,
      name: resource.name,
      kind: resource.kind,
      rack_id: neighbor.rack_id,
      state: placement_state(placement)
    })
  end

  defp select_state(query, %Rule{}) do
    select(query, [resource, placement: placement], %{
      id: resource.id,
      name: resource.name,
      kind: resource.kind,
      rack_id: type(^nil, :binary_id),
      state: placement_state(placement)
    })
  end

  # Each source's latest successful report of each resource, so a host that
  # moved networks or changed labels matches on what it says now.
  defp latest_reports(organization_id) do
    from observation in Observation,
      join: reconciliation in ObservationReconciliation,
      on:
        reconciliation.observation_id == observation.id and
          reconciliation.organization_id == ^organization_id,
      where: observation.organization_id == ^organization_id,
      where: reconciliation.status == "succeeded",
      where: not is_nil(reconciliation.matched_resource_id),
      distinct: [reconciliation.matched_resource_id, observation.source_id],
      order_by: [
        asc: reconciliation.matched_resource_id,
        asc: observation.source_id,
        desc: observation.observed_at,
        desc: observation.id
      ],
      select: %{
        resource_id: reconciliation.matched_resource_id,
        reported_from: observation.reported_from,
        intake_api_key_id: observation.intake_api_key_id,
        payload: observation.payload
      }
  end

  # Resources whose current LLDP neighbors are switches placed in exactly
  # one rack. Neighbors in two racks are a cabling question for a person.
  defp neighbor_racks(organization_id) do
    now = Renga.Time.utc_now_ms()

    from interface in Interface,
      join: evidence in InterfaceNeighborEvidence,
      on:
        evidence.local_interface_id == interface.id and
          evidence.organization_id == ^organization_id,
      join: match in InterfaceNeighborMatch,
      on:
        match.interface_neighbor_evidence_id == evidence.id and
          match.organization_id == ^organization_id,
      join: remote in Interface,
      on: remote.id == match.remote_interface_id and remote.organization_id == ^organization_id,
      join: switch in Resource,
      on: switch.id == remote.resource_id and switch.organization_id == ^organization_id,
      join: placement in CurrentPlacement,
      on: placement.resource_id == switch.id and placement.organization_id == ^organization_id,
      where: interface.organization_id == ^organization_id,
      where: is_nil(evidence.stale_at),
      where: is_nil(evidence.expires_at) or evidence.expires_at > ^now,
      where: match.status == "matched",
      where: switch.kind == "switch",
      where: not is_nil(placement.rack_id),
      group_by: interface.resource_id,
      having: count(placement.rack_id, :distinct) == 1,
      select: %{
        resource_id: interface.resource_id,
        rack_id: type(fragment("(array_agg(?))[1]", placement.rack_id), :binary_id)
      }
  end

  # Patterns only contain [a-z0-9.-_*]; `_` is a LIKE wildcard, so escape it.
  defp glob_to_like(pattern) do
    pattern
    |> String.replace("_", "\\_")
    |> String.replace("*", "%")
  end

  ## Preview

  defp summarize(scope, rule) do
    matches = subquery(match_query(scope, rule))

    counts =
      from(match in matches, group_by: match.state, select: {match.state, count()})
      |> Repo.all()
      |> Map.new()

    examples =
      from(match in matches,
        where: match.state == "will_set",
        order_by: [asc: match.name],
        limit: @preview_examples
      )
      |> Repo.all()

    %{
      will_set: Map.get(counts, "will_set", 0),
      has_value: Map.get(counts, "has_value", 0),
      set_by_person: Map.get(counts, "set_by_person", 0),
      examples: examples
    }
  end

  ## Applying

  defp apply_saved({:ok, %Rule{enabled: false} = rule}, _scope),
    do: {:ok, %{rule: rule, applied: 0}}

  defp apply_saved({:ok, %Rule{} = rule}, scope) do
    rule = Repo.preload(rule, @preloads, force: true)
    {:ok, %{rule: rule, applied: apply_rule(scope, rule, [])}}
  end

  defp apply_saved({:error, reason}, _scope), do: {:error, reason}

  # Fills the fact on every match that lacks it, re-checking each resource
  # under its lock. Returns how many facts it set.
  defp apply_rule(scope, rule, opts) do
    query = match_query(scope, rule)

    query =
      case Keyword.get(opts, :resource_id) do
        nil -> query
        id -> where(query, [resource], resource.id == ^id)
      end

    rule = Repo.preload(rule, [:site, :location, :team])

    from(match in subquery(query), where: match.state == "will_set", order_by: match.id)
    |> Repo.all()
    |> Enum.count(&(fill!(scope, rule, &1) == :filled))
  end

  defp fill!(scope, %Rule{kind: "ownership"} = rule, match) do
    case Inventory.fill_resource_owner!(scope, match.id, rule.team_id, rule.id) do
      :skipped ->
        :skipped

      {:filled, _resource} ->
        record!(scope, rule, match.id, "owner_team", %{
          "team_id" => rule.team.id,
          "name" => rule.team.name
        })
    end
  end

  defp fill!(scope, rule, match) do
    case DCIM.fill_current_placement!(scope, match.id, placement_attrs(rule, match)) do
      :skipped ->
        :skipped

      {:filled, placement} ->
        record!(scope, rule, match.id, "placement", placement_value(placement))
    end
  end

  defp placement_attrs(rule, match) do
    target =
      case rule.kind do
        "top_of_rack" -> %{rack_id: match.rack_id}
        "network_location" -> %{site_id: rule.site_id, location_id: rule.location_id}
      end

    Map.merge(target, %{
      confirmed: false,
      provenance: %{"via" => "triage_rule", "rule_id" => rule.id, "rule_name" => rule.name}
    })
  end

  defp placement_value(placement) do
    placement = Repo.preload(placement, site: :resource, location: :resource, rack: :resource)

    name =
      [placement.site, placement.location, placement.rack]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" / ", & &1.resource.name)

    %{
      "value" => name,
      "site_id" => placement.site_id,
      "location_id" => placement.location_id,
      "rack_id" => placement.rack_id
    }
  end

  defp record!(scope, rule, resource_id, field, value) do
    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "rule_applied",
        field: field,
        resource_id: resource_id,
        new_value: value,
        metadata: %{"rule_id" => rule.id, "rule_name" => rule.name, "rule_kind" => rule.kind},
        occurred_at: Renga.Time.utc_now_ms()
      })

    :filled
  end

  defp enabled_rules?(organization_id) do
    Rule
    |> where([rule], rule.organization_id == ^organization_id and rule.enabled)
    |> Repo.exists?()
  end

  defp enabled_rules(organization_id) do
    Rule
    |> where([rule], rule.organization_id == ^organization_id and rule.enabled)
    |> order_by([rule], asc: rule.inserted_at, asc: rule.id)
    |> Repo.all()
  end

  ## References

  # Sites, locations, teams, and intake keys must be the caller's; the
  # composite foreign keys would reject others, but only with a raw error.
  defp validate_references(changeset, %Scope{organization_id: organization_id}) do
    changeset
    |> validate_reference(:site_id, Site, organization_id)
    |> validate_reference(:location_id, Location, organization_id)
    |> validate_reference(:team_id, Team, organization_id)
    |> validate_reference(:intake_api_key_id, IntakeApiKey, organization_id)
    |> validate_location_in_site(organization_id)
  end

  defp validate_reference(changeset, field, schema, organization_id) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, id ->
      exists? =
        schema
        |> where([record], record.id == ^id and record.organization_id == ^organization_id)
        |> Repo.exists?()

      if exists?, do: [], else: [{field, "is not in this organization"}]
    end)
  end

  defp validate_location_in_site(changeset, organization_id) do
    site_id = Ecto.Changeset.get_field(changeset, :site_id)
    location_id = Ecto.Changeset.get_field(changeset, :location_id)

    in_site? =
      is_nil(location_id) or is_nil(site_id) or
        Location
        |> where([location], location.id == ^location_id)
        |> where([location], location.organization_id == ^organization_id)
        |> where([location], location.site_id == ^site_id)
        |> Repo.exists?()

    if in_site?,
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :location_id, "is not at that site")
  end

  ## Transactions

  defp lock_rule!(%Scope{organization_id: organization_id}, id) do
    Rule
    |> where([rule], rule.id == ^id and rule.organization_id == ^organization_id)
    |> lock("FOR UPDATE")
    |> Repo.one() || Repo.rollback(:not_found)
  end

  defp managed(%Scope{} = scope, mutation), do: transaction(scope, mutation)

  defp transaction(%Scope{organization_id: organization_id} = scope, mutation) do
    Repo.transaction(fn ->
      authorize!(scope)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  defp authorize!(%Scope{user: nil, roles: roles, organization_id: organization_id}) do
    unless @system_role in roles and active_organization?(organization_id),
      do: Repo.rollback(:forbidden)
  end

  defp authorize!(%Scope{
         membership_id: membership_id,
         user: %{id: user_id},
         organization_id: organization_id
       })
       when not is_nil(membership_id) do
    manager? =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.status == "active")
      |> where([membership], membership.role in ["owner", "admin"])
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    unless active_organization?(organization_id) and manager?, do: Repo.rollback(:forbidden)
  end

  defp authorize!(%Scope{}), do: Repo.rollback(:forbidden)

  defp active_organization?(organization_id) do
    Organization
    |> where([organization], organization.id == ^organization_id)
    |> where([organization], organization.status == "active")
    |> lock("FOR UPDATE")
    |> Repo.exists?()
  end
end
