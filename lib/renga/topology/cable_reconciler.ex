defmodule Renga.Topology.CableReconciler do
  @moduledoc false

  # Cable reconciliation selects one current cable per endpoint from confirmed
  # assertions, then explains disagreement with plans and neighbor evidence.
  # Proposed assertions are deliberately invisible here: evidence may suggest a
  # cable but only an operator or trusted import can create, move, or remove one.

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Interface
  alias Renga.Repo
  alias Renga.Topology.Cable
  alias Renga.Topology.CableAssertion
  alias Renga.Topology.CableAttributes
  alias Renga.Topology.CableChangeEvent
  alias Renga.Topology.CablePlan
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Topology.TopologyFinding

  @confirmed_kinds ~w(operator import)

  @finding_kinds ~w(cable_endpoint_conflict cable_endpoint_infeasible cable_neighbor_mismatch cable_plan_conflict cable_plan_drift cable_plan_infeasible)

  @plan_attribute_fields ~w(cable_type label color length_value length_unit description)a

  @infeasible_message "Planned endpoint cannot be cabled"
  @endpoint_infeasible_message "Cabled endpoint is no longer physically connectable"
  @conflict_message "Planned endpoint is terminated by a different cable"
  @state_lock "cable-state"
  @proposal_owned_keys ~w(kind action confirmation asserted_at interface_a_id interface_b_id)a

  @doc """
  Serializes cable state transitions for one organization.

  Assertions, plans, and reconciliation read the same claim set before writing,
  so they share one transaction-scoped lock. Holding it for the whole mutation
  keeps a concurrent reconcile from reverting a just-confirmed cable.
  """
  def lock_state!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [
      organization_id,
      @state_lock
    ])
  end

  @doc "Rebuilds current cables, plan feasibility, and evidence disagreement findings."
  def reconcile(%Scope{organization_id: organization_id}) do
    lock_state!(organization_id)
    now = Renga.Time.utc_now_ms()
    {cables, conflict_findings} = rebuild_current_cables(organization_id, now)

    findings =
      conflict_findings ++
        endpoint_infeasibility_findings(organization_id, cables, now) ++
        plan_findings(organization_id, cables, now) ++
        neighbor_findings(organization_id, cables, now)

    reconcile_findings(organization_id, findings, now)
    list_cables(organization_id)
  end

  def list_cables(organization_id, opts \\ []) do
    Cable
    |> where([cable], cable.organization_id == ^organization_id)
    |> maybe_where_interface(Keyword.get(opts, :interface_id))
    |> order_by([cable], asc: cable.interface_a_id, asc: cable.interface_b_id)
    |> preload([:interface_a, :interface_b, :primary_assertion])
    |> Repo.all()
  end

  @doc "Only physically connectable interfaces can terminate a direct cable."
  def physically_connectable?(%Interface{kind: "ethernet"}), do: true
  def physically_connectable?(_interface), do: false

  @doc """
  Records a candidate assertion from fresh, matched neighbor evidence.

  The proposal is attributed to the evidence and stays invisible to cable
  reconciliation, so evidence can suggest adjacency without moving cabling.
  Expired, superseded, or withdrawn evidence is rejected: its historical
  matched row is not current truth.
  """
  def propose_from_evidence(organization_id, evidence_id, caller_attrs) do
    evidence =
      InterfaceNeighborEvidence
      |> where([item], item.organization_id == ^organization_id and item.id == ^evidence_id)
      |> Repo.one!()

    match =
      Repo.get_by(InterfaceNeighborMatch,
        organization_id: organization_id,
        interface_neighbor_evidence_id: evidence.id
      )

    if is_nil(match) or match.status != "matched" do
      Repo.rollback(:neighbor_evidence_unresolved)
    end

    # Expiry can elapse before the sweep marks `stale_at`, so freshness is
    # checked against the server clock instead of only the stale marker.
    if not is_nil(evidence.stale_at) or
         DateTime.compare(evidence.expires_at, Renga.Time.utc_now_ms()) != :gt do
      Repo.rollback(:neighbor_evidence_stale)
    end

    existing =
      CableAssertion
      |> where(
        [assertion],
        assertion.organization_id == ^organization_id and
          assertion.interface_neighbor_evidence_id == ^evidence.id
      )
      |> Repo.one()

    # The proposal's endpoints and classification are facts about the evidence,
    # never caller input: otherwise a caller could attribute a claim about one
    # pair of interfaces to evidence for a different pair.
    {interface_a_id, interface_b_id} =
      canonical_pair(evidence.local_interface_id, match.remote_interface_id)

    attrs =
      caller_attrs
      |> Map.drop(@proposal_owned_keys ++ Enum.map(@proposal_owned_keys, &Atom.to_string/1))
      |> put_attr(:kind, "neighbor_evidence")
      |> put_attr(:action, "assert")
      |> put_attr(:confirmation, "proposed")
      |> put_attr(:asserted_at, evidence.observed_at)
      |> put_attr(:interface_a_id, interface_a_id)
      |> put_attr(:interface_b_id, interface_b_id)

    existing ||
      %CableAssertion{
        organization_id: organization_id,
        interface_neighbor_evidence_id: evidence.id
      }
      |> CableAssertion.changeset(attrs)
      |> insert_or_rollback()
  end

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, key, value),
      else: Map.put(attrs, Atom.to_string(key), value)
  end

  defp rebuild_current_cables(organization_id, now) do
    claims_by_pair = effective_claims(organization_id)

    {selected, blocked} =
      claims_by_pair
      |> Map.values()
      |> Enum.filter(&(&1.action == "assert"))
      |> select_claims()

    existing = list_cables(organization_id)
    existing_by_pair = Map.new(existing, &{pair_key(&1), &1})
    selected_pairs = MapSet.new(selected, &pair_key/1)
    selected_by_endpoint = endpoint_index(selected)

    # Retire superseded cabling before installing new cabling so an endpoint
    # that moves from one cable to another is never double-terminated.
    existing
    |> Enum.reject(&MapSet.member?(selected_pairs, pair_key(&1)))
    |> Enum.each(fn cable ->
      remove_cable(cable, removal_cause(cable, claims_by_pair, selected_by_endpoint), now)
    end)

    cables =
      Enum.map(selected, fn assertion ->
        case Map.get(existing_by_pair, pair_key(assertion)) do
          nil -> create_cable(organization_id, assertion, now)
          cable -> update_cable(cable, assertion, now)
        end
      end)

    {cables, conflict_findings(blocked, selected, now)}
  end

  defp effective_claims(organization_id) do
    CableAssertion
    |> where([assertion], assertion.organization_id == ^organization_id)
    |> where([assertion], assertion.kind in ^@confirmed_kinds)
    |> order_by([assertion], asc: assertion.asserted_at, asc: assertion.sequence)
    |> Repo.all()
    |> Enum.reduce(%{}, fn assertion, claims ->
      Map.put(claims, pair_key(assertion), assertion)
    end)
  end

  # A removed cable is explained by the claim that displaced it: the retraction
  # for its own pair, or the highest-precedence selected claim that took one of
  # its endpoints. Precedence must match selection rather than endpoint order: a
  # newer claim on the second endpoint displaced the cable even when a
  # reactivated older claim also touches the first.
  defp removal_cause(cable, claims_by_pair, selected_by_endpoint) do
    case Map.get(claims_by_pair, pair_key(cable)) do
      %{action: "retract"} = retraction ->
        retraction

      _claim_or_nil ->
        cable
        |> cable_endpoints()
        |> Enum.map(&Map.get(selected_by_endpoint, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&{DateTime.to_unix(&1.asserted_at, :microsecond), &1.sequence}, fn ->
          nil
        end)
    end
  end

  # Newest confirmed claim wins an endpoint, ordered by assertion time and then
  # by insertion sequence so same-millisecond claims are still deterministic.
  # Older competing claims stay in the database as history and become findings
  # instead of silently replacing it.
  defp select_claims(claims) do
    claims
    |> Enum.sort_by(&{DateTime.to_unix(&1.asserted_at, :microsecond), &1.sequence}, :desc)
    |> Enum.reduce({[], [], MapSet.new()}, fn claim, {selected, blocked, occupied} ->
      endpoints = MapSet.new([claim.interface_a_id, claim.interface_b_id])

      if MapSet.disjoint?(occupied, endpoints) do
        {[claim | selected], blocked, MapSet.union(occupied, endpoints)}
      else
        {selected, [claim | blocked], occupied}
      end
    end)
    |> then(fn {selected, blocked, _occupied} ->
      {Enum.reverse(selected), Enum.reverse(blocked)}
    end)
  end

  defp create_cable(organization_id, assertion, now) do
    cable =
      %Cable{
        organization_id: organization_id,
        interface_a_id: assertion.interface_a_id,
        interface_b_id: assertion.interface_b_id,
        primary_assertion_id: assertion.id
      }
      |> Ecto.Changeset.change(last_asserted_at: assertion.asserted_at)
      |> Cable.changeset(cable_attributes(assertion))
      |> insert_or_rollback()

    record_event(cable, "created", %{}, assertion, now)
    cable
  end

  defp update_cable(cable, assertion, now) do
    attrs = cable_attributes(assertion)
    changes = attribute_changes(cable, attrs)

    cable =
      cable
      |> Ecto.Changeset.change(
        primary_assertion_id: assertion.id,
        last_asserted_at: assertion.asserted_at
      )
      |> Cable.changeset(attrs)
      |> update_or_rollback()

    if changes != %{}, do: record_event(cable, "updated", changes, assertion, now)
    cable
  end

  defp remove_cable(cable, cause, now) do
    # Record before deleting: the history row keeps the cable identity as an
    # opaque reference, so the removal remains explainable afterwards.
    record_event(cable, "removed", %{}, cause, now)
    Repo.delete!(cable)
  end

  # Every event carries the causing claim, its attribution, and a snapshot of
  # the cable attributes at that moment, so history explains itself even after
  # the projection row is gone.
  defp record_event(cable, action, changes, cause, now) do
    %CableChangeEvent{
      organization_id: cable.organization_id,
      cable_id: cable.id,
      assertion_id: cause && cause.id,
      interface_a_id: cable.interface_a_id,
      interface_b_id: cable.interface_b_id,
      source_id: cause && cause.source_id,
      actor_user_id: cause && cause.actor_user_id
    }
    |> CableChangeEvent.changeset(%{
      action: action,
      changes: changes,
      snapshot: cable_snapshot(cable),
      occurred_at: now
    })
    |> insert_or_rollback()
  end

  defp cable_snapshot(cable) do
    %{
      "cable_type" => cable.cable_type,
      "status" => cable.status,
      "label" => cable.label,
      "color" => cable.color,
      "length_value" => cable.length_value && Decimal.to_string(cable.length_value),
      "length_unit" => cable.length_unit,
      "description" => cable.description
    }
  end

  defp conflict_findings(blocked, selected, now) do
    selected_by_endpoint = endpoint_index(selected)

    Enum.flat_map(blocked, &blocked_claim_findings(&1, selected_by_endpoint, now))
  end

  defp blocked_claim_findings(claim, selected_by_endpoint, now) do
    [claim.interface_a_id, claim.interface_b_id]
    |> Enum.flat_map(&blocked_endpoint_finding(claim, selected_by_endpoint, &1, now))
  end

  defp blocked_endpoint_finding(claim, selected_by_endpoint, interface_id, now) do
    case Map.get(selected_by_endpoint, interface_id) do
      nil ->
        []

      selected_claim ->
        [
          finding(
            interface_id,
            "cable_endpoint_conflict",
            pair_key(claim),
            "Confirmed cable assertions compete for one endpoint",
            %{
              "assertion_id" => claim.id,
              "selected_assertion_id" => selected_claim.id,
              "interface_a_id" => claim.interface_a_id,
              "interface_b_id" => claim.interface_b_id
            },
            now
          )
        ]
    end
  end

  defp plan_findings(organization_id, cables, now) do
    plans =
      CablePlan
      |> where([plan], plan.organization_id == ^organization_id)
      |> Repo.all()

    if plans == [] do
      []
    else
      interfaces = interfaces_by_id(organization_id, Enum.flat_map(plans, &plan_endpoints/1))
      cable_by_endpoint = cable_endpoint_index(cables)

      Enum.flat_map(plans, &plan_findings_for(&1, interfaces, cable_by_endpoint, now))
    end
  end

  defp plan_findings_for(plan, interfaces, cable_by_endpoint, now) do
    infeasible =
      [plan.interface_a_id, plan.interface_b_id]
      |> Enum.reject(&physically_connectable?(Map.get(interfaces, &1)))

    conflicts = conflict_endpoints(plan, cable_by_endpoint)

    cond do
      infeasible != [] ->
        Enum.map(
          infeasible,
          &plan_finding(plan, "cable_plan_infeasible", @infeasible_message, now, &1)
        )

      conflicts != [] ->
        Enum.map(
          conflicts,
          &plan_finding(plan, "cable_plan_conflict", @conflict_message, now, &1)
        )

      true ->
        drift_finding(plan, cable_by_endpoint, now)
    end
  end

  defp conflict_endpoints(plan, cable_by_endpoint) do
    Enum.filter([plan.interface_a_id, plan.interface_b_id], fn interface_id ->
      case Map.get(cable_by_endpoint, interface_id) do
        nil ->
          false

        {_cable, remote_interface_id} ->
          remote_interface_id != other_plan_endpoint(plan, interface_id)
      end
    end)
  end

  defp drift_finding(plan, cable_by_endpoint, now) do
    with {cable, _remote} <- Map.get(cable_by_endpoint, plan.interface_a_id, :none),
         {_other, _remote} <- Map.get(cable_by_endpoint, plan.interface_b_id, :none),
         false <- plan_matches_cable?(plan, cable) do
      [
        plan_finding(
          plan,
          "cable_plan_drift",
          "Current cable attributes differ from the plan",
          now
        )
      ]
    else
      _ -> []
    end
  end

  defp plan_matches_cable?(plan, cable) do
    Enum.all?(@plan_attribute_fields, fn field ->
      CableAttributes.same_value?(Map.get(plan, field), Map.get(cable, field))
    end)
  end

  defp plan_finding(plan, kind, message, now, interface_id \\ nil) do
    finding(
      interface_id || plan.interface_a_id,
      kind,
      "plan:#{pair_key(plan)}",
      message,
      %{
        "plan_id" => plan.id,
        "interface_a_id" => plan.interface_a_id,
        "interface_b_id" => plan.interface_b_id
      },
      now
    )
  end

  # A collector can reclassify an interface after cabling was confirmed. The
  # cable is retained (only an operator or import may remove it), so the
  # contradiction becomes a finding rather than a silent deletion.
  defp endpoint_infeasibility_findings(organization_id, cables, now) do
    if cables == [] do
      []
    else
      interfaces = interfaces_by_id(organization_id, Enum.flat_map(cables, &cable_endpoints/1))
      Enum.flat_map(cables, &infeasible_endpoint_findings(&1, interfaces, now))
    end
  end

  defp infeasible_endpoint_findings(cable, interfaces, now) do
    cable
    |> cable_endpoints()
    |> Enum.reject(&physically_connectable?(Map.get(interfaces, &1)))
    |> Enum.map(fn interface_id ->
      finding(
        interface_id,
        "cable_endpoint_infeasible",
        "cable:#{pair_key(cable)}",
        @endpoint_infeasible_message,
        %{
          "cable_id" => cable.id,
          "interface_a_id" => cable.interface_a_id,
          "interface_b_id" => cable.interface_b_id
        },
        now
      )
    end)
  end

  defp cable_endpoints(cable), do: [cable.interface_a_id, cable.interface_b_id]

  defp neighbor_findings(organization_id, cables, now) do
    if cables == [] do
      []
    else
      adjacency_by_endpoint = adjacency_index(organization_id)
      Enum.flat_map(cables, &cable_mismatch_findings(&1, adjacency_by_endpoint, now))
    end
  end

  defp cable_mismatch_findings(cable, adjacency_by_endpoint, now) do
    [cable.interface_a_id, cable.interface_b_id]
    |> Enum.flat_map(&endpoint_mismatch_finding(cable, adjacency_by_endpoint, &1, now))
  end

  defp endpoint_mismatch_finding(cable, adjacency_by_endpoint, interface_id, now) do
    conflicting =
      adjacency_by_endpoint
      |> Map.get(interface_id, [])
      |> Enum.reject(&(&1 == other_endpoint(cable, interface_id)))

    if conflicting == [] do
      []
    else
      [
        finding(
          interface_id,
          "cable_neighbor_mismatch",
          "cable:#{pair_key(cable)}",
          "Observed adjacency disagrees with confirmed cabling",
          %{"cable_id" => cable.id, "remote_interface_ids" => Enum.sort(conflicting)},
          now
        )
      ]
    end
  end

  defp adjacency_index(organization_id) do
    CurrentInterfaceAdjacency
    |> where([adjacency], adjacency.organization_id == ^organization_id)
    |> Repo.all()
    |> Enum.flat_map(fn adjacency ->
      [
        {adjacency.interface_a_id, adjacency.interface_b_id},
        {adjacency.interface_b_id, adjacency.interface_a_id}
      ]
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp reconcile_findings(organization_id, findings, now) do
    keys = MapSet.new(findings, &{&1.interface_id, &1.kind, &1.resolution_key})
    Enum.each(findings, &put_finding(organization_id, &1))

    TopologyFinding
    |> where([finding], finding.organization_id == ^organization_id)
    |> where([finding], finding.status == "open" and finding.kind in ^@finding_kinds)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keys, {&1.interface_id, &1.kind, &1.resolution_key}))
    |> Enum.each(&resolve_finding(&1, now))
  end

  defp put_finding(organization_id, finding) do
    existing =
      Repo.get_by(TopologyFinding,
        organization_id: organization_id,
        interface_id: finding.interface_id,
        kind: finding.kind,
        resolution_key: finding.resolution_key,
        status: "open"
      )

    attrs =
      if existing do
        Map.update!(finding, :last_observed_at, &max_datetime(&1, existing.last_observed_at))
      else
        finding
      end

    (existing ||
       %TopologyFinding{organization_id: organization_id, interface_id: finding.interface_id})
    |> TopologyFinding.changeset(Map.merge(attrs, %{status: "open", resolved_at: nil}))
    |> Repo.insert_or_update()
    |> unwrap_or_rollback()
  end

  defp resolve_finding(finding, now) do
    resolved_at = max_datetime(now, finding.last_observed_at)

    finding
    |> TopologyFinding.changeset(%{status: "resolved", resolved_at: resolved_at})
    |> update_or_rollback()
  end

  defp finding(interface_id, kind, resolution_key, message, details, now) do
    %{
      interface_id: interface_id,
      kind: kind,
      resolution_key: resolution_key,
      message: message,
      details: details,
      last_observed_at: now
    }
  end

  defp endpoint_index(claims) do
    Enum.reduce(claims, %{}, fn claim, index ->
      index
      |> Map.put(claim.interface_a_id, claim)
      |> Map.put(claim.interface_b_id, claim)
    end)
  end

  defp cable_endpoint_index(cables) do
    Enum.reduce(cables, %{}, fn cable, index ->
      index
      |> Map.put(cable.interface_a_id, {cable, cable.interface_b_id})
      |> Map.put(cable.interface_b_id, {cable, cable.interface_a_id})
    end)
  end

  defp interfaces_by_id(organization_id, interface_ids) do
    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> where([interface], interface.id in ^Enum.uniq(interface_ids))
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp plan_endpoints(plan), do: [plan.interface_a_id, plan.interface_b_id]

  defp other_plan_endpoint(plan, interface_id) do
    if interface_id == plan.interface_a_id, do: plan.interface_b_id, else: plan.interface_a_id
  end

  defp other_endpoint(cable, interface_id) do
    if interface_id == cable.interface_a_id, do: cable.interface_b_id, else: cable.interface_a_id
  end

  defp cable_attributes(assertion) do
    %{
      cable_type: assertion.cable_type,
      status: assertion.status || "connected",
      label: assertion.label,
      color: assertion.color,
      length_value: assertion.length_value,
      length_unit: assertion.length_unit,
      description: assertion.description,
      metadata: assertion.metadata
    }
  end

  defp attribute_changes(cable, attrs) do
    CableAttributes.fields()
    |> Enum.reduce(%{}, fn field, changes ->
      from = Map.get(cable, field)
      to = Map.get(attrs, field)

      if CableAttributes.same_value?(from, to) do
        changes
      else
        Map.put(changes, to_string(field), %{"from" => from, "to" => to})
      end
    end)
  end

  defp pair_key(%{interface_a_id: interface_a_id, interface_b_id: interface_b_id}),
    do: "#{interface_a_id}:#{interface_b_id}"

  defp canonical_pair(first, second),
    do: if(first < second, do: {first, second}, else: {second, first})

  defp maybe_where_interface(query, nil), do: query

  defp maybe_where_interface(query, interface_id) do
    where(
      query,
      [cable],
      cable.interface_a_id == ^interface_id or cable.interface_b_id == ^interface_id
    )
  end

  defp max_datetime(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp insert_or_rollback(changeset), do: changeset |> Repo.insert() |> unwrap_or_rollback()
  defp update_or_rollback(changeset), do: changeset |> Repo.update() |> unwrap_or_rollback()

  defp unwrap_or_rollback({:ok, result}), do: result
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
end
