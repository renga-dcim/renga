defmodule Renga.Transfers.RecordTypes do
  @moduledoc """
  The record types of an organization export (RFD 20), format version 1.

  Each record type is one organization-owned table, exported with an
  allowlist of fields. A field the list does not name is never exported, so
  a column added by a later migration stays out of archives until someone
  decides what it means for a move. The suite fails until every column of
  every organization-owned table is either exported or excluded here with a
  reason (`excluded_fields/0`, `excluded_tables/0`), which is what keeps
  credentials out.

  Record types are listed in dependency order: a record only refers to
  records of earlier types, except through `deferred` fields, which close a
  cycle (a host source names its agent and the agent names its source) and
  are set once both records exist. The importer relies on that order.

  Organization-owned records keep their IDs. Fields that name a person
  (`principal_fields`) refer to a principal in `principals.ndjson`, never to
  a destination account: the principal ID is the source user's ID, which
  means nothing in another deployment.

  `organization` holds the organization's portable settings and
  `principals` the people the other records refer to; both are exported
  specially, by `Renga.Transfers.Export`.

  Parts (`Renga.Transfers.Archive.parts/0`):

    * `:current` record types are always exported;
    * `:history` record types only when the export includes history;
    * `observations` are current state, but only those that current evidence
      and claims require (and their parent reports), unless the export
      includes `raw_observations`.
  """

  # {record type, part, exported fields}
  @record_types [
    {"addressing_plan_levels", :current,
     ~w(id family prefix_length name created_by_id inserted_at updated_at)},
    {"intake_api_keys", :current, ~w(id name status inserted_at updated_at)},
    {"organization_memberships", :current,
     ~w(id user_id role status metadata inserted_at updated_at)},
    {"roles", :current, ~w(id name description permissions inserted_at updated_at)},
    {"saved_views", :current,
     ~w(id user_id created_by_id area name params pinned inserted_at updated_at)},
    {"sources", :current,
     ~w(id kind name status metadata inserted_at updated_at authoritative_routing_domains agent_id collector_id)},
    {"teams", :current, ~w(id name description inserted_at updated_at)},
    {"agents", :current,
     ~w(id source_id name status version capabilities metadata registered_at inserted_at updated_at installation_id last_contacted_at)},
    {"cable_import_contracts", :current,
     ~w(id source_id granted_by_id granted_at revoked_by_id revoked_at inserted_at updated_at)},
    {"resources", :current,
     ~w(id kind name display_name lifecycle_state spec generation resource_version labels annotations deletion_requested_at inserted_at updated_at owner_team_id owner_source owner_set_at owner_rule_id)},
    {"role_assignments", :current,
     ~w(id membership_id built_in_role role_id valid_until expired_at source reason created_by_user_id inserted_at)},
    {"sync_runs", :current,
     ~w(id source_id status started_at completed_at resource_count error_count metadata inserted_at updated_at)},
    {"team_memberships", :current, ~w(id team_id membership_id added_by_user_id inserted_at)},
    {"actual_components", :current,
     ~w(id owner_resource_id kind status name model slot path serial_number part_number attributes metadata first_observed_at last_observed_at inserted_at updated_at)},
    {"change_requests", :current,
     ~w(id resource_id kind field before_value after_value reason status requested_by_user_id decided_by_user_id decided_at decision_note inserted_at updated_at)},
    {"collector_findings", :current,
     ~w(id resource_id agent_id kind status message details last_observed_at resolved_at inserted_at updated_at)},
    {"component_findings", :current,
     ~w(id resource_id kind resolution_key status message details resolved_at last_observed_at inserted_at updated_at)},
    {"finding_workflows", :current,
     ~w(id resource_id domain subject_id kind resolution_key assignee_user_id snoozed_until exception_reason exception_expires_at exception_at exception_by_user_id inserted_at updated_at)},
    {"hardware_match_findings", :current,
     ~w(id resource_id kind status message details resolved_at inserted_at updated_at)},
    {"hosts", :current,
     ~w(id resource_id hostname fqdn vendor model asset_tag metadata inserted_at updated_at)},
    {"installation_keys", :current,
     ~w(id agent_id algorithm public_key fingerprint status first_presented_at last_presented_at approved_at approved_by_user_id replaced_at inserted_at updated_at)},
    {"interfaces", :current,
     ~w(id resource_id name mac_address kind status mtu speed_mbps metadata inserted_at updated_at)},
    {"manufacturers", :current,
     ~w(id resource_id slug description metadata inserted_at updated_at)},
    {"module_bays", :current,
     ~w(id owner_resource_id owner_kind name label position status metadata inserted_at updated_at)},
    {"observations", :current,
     ~w(id source_id sync_run_id idempotency_key observed_at payload_digest payload inserted_at reported_from intake_api_key_id parent_observation_id resource_index)},
    {"placement_findings", :current,
     ~w(id resource_id kind status message details resolved_at inserted_at updated_at)},
    {"power_ports", :current,
     ~w(id resource_id name label connector maximum_draw_w default_allocated_draw_w allocated_draw_w inserted_at updated_at retired_at default_power_factor power_factor)},
    {"resource_conditions", :current,
     ~w(id resource_id type status reason message observed_generation last_transition_at details inserted_at updated_at)},
    {"resource_identifiers", :current,
     ~w(id resource_id kind value normalized_value metadata inserted_at updated_at)},
    {"resource_overrides", :current,
     ~w(id resource_id field value reason created_by_user_id inserted_at updated_at)},
    {"resource_owners", :current,
     ~w(id owner_resource_id child_resource_id kind controller metadata inserted_at updated_at)},
    {"resource_relationships", :current,
     ~w(id source_resource_id target_resource_id kind metadata inserted_at updated_at)},
    {"resource_revisions", :history,
     ~w(id resource_id revision action generation snapshot inserted_at)},
    {"site_groups", :current,
     ~w(id resource_id parent_id description metadata inserted_at updated_at)},
    {"vrfs", :current,
     ~w(id resource_id name route_distinguisher status description metadata inserted_at updated_at)},
    {"address_findings", :current,
     ~w(id interface_id kind resolution_key status message details last_observed_at resolved_at inserted_at updated_at)},
    {"addresses", :current,
     ~w(id resource_id interface_id kind address scope metadata inserted_at updated_at)},
    {"cable_change_events", :history,
     ~w(id sequence cable_id assertion_id interface_a_id interface_b_id source_id action changes snapshot occurred_at actor_user_id metadata inserted_at cable_kind power_port_id power_outlet_id power_feed_id)},
    {"change_events", :history,
     ~w(id resource_id source_id sync_run_id observation_id kind field old_value new_value metadata occurred_at inserted_at updated_at actor_user_id finding_workflow_id)},
    {"collector_targets", :current,
     ~w(id source_id key status error last_reported_at last_reachable_at last_complete_at last_observation_id inserted_at updated_at)},
    {"component_evidence", :current,
     ~w(id resource_id source_id observation_id kind source_local_id name model slot path serial_number part_number attributes raw_metadata observed_at inserted_at updated_at)},
    {"desired_interface_vlan_modes", :current,
     ~w(id interface_id mode metadata inserted_at updated_at)},
    {"hardware_types", :current,
     ~w(id resource_id manufacturer_id model device_class description metadata inserted_at updated_at auto_move)},
    {"interface_neighbor_evidence", :current,
     ~w(id local_interface_id source_id observation_id protocol remote_chassis_id remote_chassis_id_kind remote_chassis_id_normalized remote_system_name remote_port_id remote_port_id_kind remote_port_id_normalized remote_port_description ttl_seconds observed_at expires_at stale_at stale_reason metadata inserted_at)},
    {"interface_relationships", :current,
     ~w(id source_interface_id target_interface_id kind metadata inserted_at updated_at)},
    {"interface_routing_domain_evidence", :current,
     ~w(id interface_id source_id observation_id source_local_key route_distinguisher metadata observed_at stale_at inserted_at)},
    {"interface_vlan_mode_evidence", :current,
     ~w(id interface_id source_id observation_id mode observed_at metadata inserted_at)},
    {"ip_addresses", :current,
     ~w(id address description adopted_by_id inserted_at updated_at resource_id vrf_id allocation_state management_mode role dns_name metadata)},
    {"module_types", :current,
     ~w(id resource_id manufacturer_id model module_class description metadata inserted_at updated_at)},
    {"observation_reconciliations", :current,
     ~w(id observation_id matched_resource_id status attempt errors metadata started_at completed_at inserted_at updated_at)},
    {"placement_evidence", :current,
     ~w(id source_id observation_id resource_id site_identifier location_identifier rack_identifier position height_units face confidence observed_at stale_at metadata inserted_at)},
    {"power_outlets", :current,
     ~w(id resource_id inlet_port_id name label connector feed_leg inserted_at updated_at retired_at)},
    {"prefixes", :current,
     ~w(id resource_id prefix status description metadata inserted_at updated_at vrf_id strict)},
    {"resource_identifier_claims", :current,
     ~w(id resource_identifier_id resource_id source_id observation_id kind value normalized_value confidence first_seen_at last_seen_at metadata inserted_at updated_at)},
    {"sites", :current,
     ~w(id resource_id site_group_id slug status description physical_address time_zone metadata inserted_at updated_at)},
    {"source_routing_domain_mappings", :current,
     ~w(id source_id source_local_key vrf_id created_by_id inserted_at updated_at)},
    {"target_bindings", :current,
     ~w(id resource_id agent_id installation_key_id version status approved_by_user_id approved_at revoked_at revoked_reason revoked_by_user_id inserted_at updated_at)},
    {"topology_findings", :current,
     ~w(id interface_id kind resolution_key status message details last_observed_at resolved_at inserted_at updated_at)},
    {"topology_snapshot_events", :current,
     ~w(id resource_id source_id observation_id section observed_at inserted_at)},
    {"actual_component_evidence_matches", :current,
     ~w(id owner_resource_id actual_component_id component_evidence_id match_strategy inserted_at)},
    {"address_evidence", :current,
     ~w(id address_id source_id observation_id address scope metadata observed_at inserted_at updated_at)},
    {"catalog_type_revisions", :current,
     ~w(id hardware_type_id module_type_id revision part_number height_units width_mm depth_mm weight_kg airflow specifications finalized_at inserted_at)},
    {"collector_target_resources", :current,
     ~w(id source_id target_id resource_id first_reported_at last_reported_at withdrawn_at inserted_at updated_at domain domain_reported_at active_since)},
    {"current_interface_adjacencies", :current,
     ~w(id interface_a_id interface_b_id primary_evidence_id confidence last_observed_at metadata inserted_at updated_at)},
    {"current_interface_vlan_modes", :current,
     ~w(id interface_id mode metadata inserted_at updated_at interface_vlan_mode_evidence_id)},
    {"interface_neighbor_matches", :current,
     ~w(id interface_neighbor_evidence_id remote_interface_id status strategy candidate_count inserted_at updated_at)},
    {"interface_relationship_evidence", :current,
     ~w(id interface_relationship_id source_id observation_id kind metadata observed_at inserted_at updated_at stale_at)},
    {"interface_routing_domains", :current,
     ~w(interface_id evidence_id source_id source_local_key route_distinguisher authoritative resolution vrf_id observed_at inserted_at updated_at)},
    {"ip_address_assignments", :current,
     ~w(id ip_address_id interface_id assigned_by_id inserted_at updated_at)},
    {"jobs", :history,
     ~w(id agent_id batch_id capability capability_version risk_class retry_class parameters requested_by_type requested_by_user_id idempotency_key state attempts max_attempts not_after leased_at lease_expires_at started_at cancel_requested_at finished_at result failure_reason output_bytes output_limit_bytes timeout_ms last_sequence inserted_at updated_at resource_id target_binding_id target_binding_version offer_expires_at)},
    {"locations", :current,
     ~w(id resource_id site_id parent_id kind status description metadata inserted_at updated_at)},
    {"module_bay_compatible_types", :current, ~w(module_bay_id module_type_id inserted_at)},
    {"component_templates", :current,
     ~w(id catalog_type_revision_id kind name label position description required attributes inserted_at)},
    {"desired_module_assignments", :current,
     ~w(id module_bay_id module_type_id confirmed_by_user_id metadata inserted_at updated_at)},
    {"hardware_assignments", :current,
     ~w(id resource_id hardware_type_id catalog_type_revision_id origin provenance inserted_at updated_at)},
    {"job_events", :history,
     ~w(id job_id sequence attempt type actor_type actor_id payload inserted_at report_sequence)},
    {"modules", :current,
     ~w(id resource_id module_type_id catalog_type_revision_id status serial_number part_number asset_tag metadata inserted_at updated_at)},
    {"power_panels", :current,
     ~w(id resource_id site_id location_id name description metadata inserted_at updated_at)},
    {"racks", :current,
     ~w(id resource_id site_id location_id status facility_id height_units width starting_unit outer_width outer_depth dimension_unit metadata inserted_at updated_at)},
    {"triage_rules", :current,
     ~w(id kind name enabled subnet intake_api_key_id hostname_pattern label_key label_value site_id location_id team_id created_by_user_id inserted_at updated_at)},
    {"vlan_groups", :current,
     ~w(id resource_id slug scope_kind site_id location_id status description metadata inserted_at updated_at)},
    {"current_module_installations", :current,
     ~w(id module_bay_id module_id module_type_id installed_at metadata inserted_at updated_at)},
    {"current_placements", :current,
     ~w(id resource_id site_id location_id rack_id position height_units face confirmed provenance inserted_at updated_at)},
    {"desired_placements", :current,
     ~w(id resource_id site_id location_id rack_id position height_units face confirmed provenance inserted_at updated_at)},
    {"expected_component_exceptions", :current,
     ~w(id hardware_assignment_id catalog_type_revision_id component_template_id action kind name changes confirmed_by_user_id inserted_at updated_at)},
    {"interface_evidence", :current,
     ~w(id interface_id source_id observation_id name mac_address kind status mtu speed_mbps metadata observed_at inserted_at updated_at component_template_id catalog_match_status catalog_match_strategy)},
    {"inventory_items", :current,
     ~w(id owner_resource_id parent_id name kind status position serial_number part_number asset_tag metadata inserted_at updated_at promoted_module_id)},
    {"module_installation_events", :history,
     ~w(id sequence module_bay_id module_id action occurred_at actor_user_id metadata inserted_at)},
    {"power_feeds", :current,
     ~w(id resource_id site_id panel_id rack_id name status supply phase voltage amperage max_utilization side description metadata inserted_at updated_at)},
    {"source_vlan_group_mappings", :current,
     ~w(id source_id vlan_group_id source_local_scope metadata inserted_at updated_at)},
    {"vlan_group_vid_ranges", :current,
     ~w(id vlan_group_id start_vid end_vid inserted_at updated_at)},
    {"vlans", :current,
     ~w(id resource_id vlan_group_id vid name status role description metadata inserted_at updated_at)},
    {"cable_assertions", :current,
     ~w(id sequence interface_a_id interface_b_id kind action confirmation actor_user_id source_id interface_neighbor_evidence_id asserted_at cable_type status label color length_value length_unit description metadata inserted_at cable_kind power_port_id power_outlet_id power_feed_id)},
    {"cable_plans", :current,
     ~w(id interface_a_id interface_b_id cable_type status label color length_value length_unit description metadata inserted_at updated_at cable_kind power_port_id power_outlet_id power_feed_id)},
    {"confirmed_components", :current,
     ~w(id hardware_assignment_id component_template_id exception_id part_number serial_number model note confirmed_by_user_id confirmed_at inserted_at updated_at)},
    {"desired_interface_vlan_assignments", :current,
     ~w(id interface_id vlan_id tagging_mode metadata inserted_at updated_at)},
    {"expected_components", :current,
     ~w(id hardware_assignment_id catalog_type_revision_id component_template_id exception_id kind name label position description required suppressed attributes inserted_at updated_at)},
    {"interface_vlan_evidence", :current,
     ~w(id interface_id vlan_id source_id observation_id source_local_key source_local_scope vid tagging_mode metadata observed_at stale_at inserted_at)},
    {"prefix_vlan_relationships", :current, ~w(id prefix_id vlan_id inserted_at updated_at)},
    {"rack_occupancies", :current,
     ~w(id current_placement_id rack_id face units inserted_at updated_at)},
    {"cables", :current,
     ~w(id interface_a_id interface_b_id primary_assertion_id cable_type status label color length_value length_unit description metadata last_asserted_at inserted_at updated_at cable_kind power_port_id power_outlet_id power_feed_id)},
    {"current_interface_vlan_memberships", :current,
     ~w(id interface_id vlan_id tagging_mode metadata inserted_at updated_at interface_vlan_evidence_id)}
  ]

  # Every field that refers to a person, as {record type, field, the SQL
  # condition under which it does, or nil when it always does}.
  @principal_fields [
    {"addressing_plan_levels", "created_by_id", nil},
    {"organization_memberships", "user_id", nil},
    {"saved_views", "user_id", nil},
    {"saved_views", "created_by_id", nil},
    {"cable_import_contracts", "granted_by_id", nil},
    {"cable_import_contracts", "revoked_by_id", nil},
    {"role_assignments", "created_by_user_id", nil},
    {"team_memberships", "added_by_user_id", nil},
    {"change_requests", "requested_by_user_id", nil},
    {"change_requests", "decided_by_user_id", nil},
    {"finding_workflows", "assignee_user_id", nil},
    {"finding_workflows", "exception_by_user_id", nil},
    {"installation_keys", "approved_by_user_id", nil},
    {"resource_overrides", "created_by_user_id", nil},
    {"cable_change_events", "actor_user_id", nil},
    {"change_events", "actor_user_id", nil},
    {"ip_addresses", "adopted_by_id", nil},
    {"source_routing_domain_mappings", "created_by_id", nil},
    {"target_bindings", "approved_by_user_id", nil},
    {"target_bindings", "revoked_by_user_id", nil},
    {"ip_address_assignments", "assigned_by_id", nil},
    {"jobs", "requested_by_user_id", nil},
    {"desired_module_assignments", "confirmed_by_user_id", nil},
    {"job_events", "actor_id", "actor_type = 'user'"},
    {"triage_rules", "created_by_user_id", nil},
    {"expected_component_exceptions", "confirmed_by_user_id", nil},
    {"module_installation_events", "actor_user_id", nil},
    {"cable_assertions", "actor_user_id", nil},
    {"confirmed_components", "confirmed_by_user_id", nil}
  ]

  # Fields that close a reference cycle; the importer sets them last.
  @deferred_fields %{
    "sources" => ~w(agent_id),
    "resources" => ~w(owner_rule_id)
  }

  # Fields that point at an observation. Without `raw_observations`, the
  # observations exported are exactly those the included records point at.
  @observation_references [
    {"address_evidence", "observation_id"},
    {"change_events", "observation_id"},
    {"collector_targets", "last_observation_id"},
    {"component_evidence", "observation_id"},
    {"interface_evidence", "observation_id"},
    {"interface_neighbor_evidence", "observation_id"},
    {"interface_relationship_evidence", "observation_id"},
    {"interface_routing_domain_evidence", "observation_id"},
    {"interface_vlan_evidence", "observation_id"},
    {"interface_vlan_mode_evidence", "observation_id"},
    {"placement_evidence", "observation_id"},
    {"resource_identifier_claims", "observation_id"},
    {"topology_snapshot_events", "observation_id"}
  ]

  # Record types whose primary key is not `id`.
  @order_by %{
    "interface_routing_domains" => ~w(interface_id),
    "module_bay_compatible_types" => ~w(module_bay_id module_type_id)
  }

  @excluded_fields %{
    "intake_api_keys" => %{
      "token_hash" => "credential: the key's hash",
      "deployment_id" => "names the source deployment (RFD 23); destination keys carry their own"
    },
    "jobs" => %{
      "lease_token_hash" => "credential: job lease",
      "report_token_hash" => "credential: job report",
      "offer_token_hash" => "credential: signed-lease offer",
      "offer_nonce" => "credential: signed-lease offer"
    }
  }

  @excluded_tables %{
    "agent_leases" => "runtime state; agents take new leases at the destination",
    "cable_endpoint_terminations" => "maintained by a trigger when a cable is inserted",
    "current_interface_adjacency_endpoints" =>
      "maintained by a trigger when an adjacency is inserted",
    "deployment_audit_events" => "the deployment's operator audit log, not organization data",
    "identity_providers" => "deployment configuration, set up at the destination",
    "organization_invitations" =>
      "pending invitations carry secrets; access returns through new invitations",
    "organization_limits" => "operator policy of the source deployment"
  }

  @organization_fields ~w(name slug settings default_accent default_power_factor inserted_at
                          updated_at)
  @principal_record_fields ~w(id email)

  @doc """
  Every record type, in dependency order, as maps with `:name`, `:part`,
  `:fields`, `:principal_fields`, `:deferred_fields`, and `:order_by`.
  """
  def all do
    principals = Enum.group_by(@principal_fields, &elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    for {name, part, fields} <- @record_types do
      %{
        name: name,
        part: part,
        fields: fields,
        principal_fields: Map.get(principals, name, []),
        deferred_fields: Map.get(@deferred_fields, name, []),
        order_by: Map.get(@order_by, name, ~w(id))
      }
    end
  end

  @doc "The record types an export with optional `parts` includes."
  def included(parts) do
    Enum.filter(all(), &(&1.part == :current or Atom.to_string(&1.part) in parts))
  end

  @doc "The fields of the `organization` record."
  def organization_fields, do: @organization_fields

  @doc "The fields of a `principals` record."
  def principal_record_fields, do: @principal_record_fields

  @doc "Fields that point at an observation, as `{record type, field}`."
  def observation_references, do: @observation_references

  @doc "Columns of exported tables that are never exported, with the reason."
  def excluded_fields, do: @excluded_fields

  @doc "Organization-owned tables that are never exported, with the reason."
  def excluded_tables, do: @excluded_tables
end
