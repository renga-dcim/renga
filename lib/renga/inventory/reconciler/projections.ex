defmodule Renga.Inventory.Reconciler.Projections do
  @moduledoc """
  Reconciles host and network facts after resource identity is resolved.

  Canonical rows retain deterministic per-field ownership in metadata while
  observation-scoped evidence remains available for source comparison.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Catalog
  alias Renga.Catalog.ActualComponent
  alias Renga.Catalog.ActualComponentEvidenceMatch
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.ComponentEvidence
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.InterfaceEvidence
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Repo
  alias Renga.Types.Inet
  alias Renga.Types.MacAddress

  @host_fields ~w(hostname fqdn vendor model asset_tag)
  @interface_fields ~w(name mac_address kind status mtu speed_mbps)
  @canonical_component_kinds ~w(cpu memory disk)

  @doc false
  def reconcile(
        %Scope{} = scope,
        %Source{} = source,
        %Observation{} = observation,
        %Resource{} = resource,
        opts \\ []
      ) do
    payload = resource_payload(observation.payload)
    overrides = Map.new(Inventory.list_resource_overrides(scope, resource.id), &{&1.field, &1})
    allow_new_rows? = Keyword.get(opts, :allow_new_rows?, true)

    reconcile_host(scope, source, observation, resource, payload, overrides)

    reconcile_component_evidence(
      scope,
      source,
      observation,
      resource,
      payload,
      allow_new_rows?
    )

    interfaces_authoritative? = Map.has_key?(payload, "interfaces")
    interfaces = Map.get(payload, "interfaces", [])

    Enum.each(
      interfaces,
      &reconcile_interface(
        scope,
        source,
        observation,
        resource,
        &1,
        overrides,
        allow_new_rows?
      )
    )

    if allow_new_rows? and interfaces_authoritative? do
      reconcile_network_omissions(scope, source, observation, resource, interfaces, overrides)
    end
  end

  defp reconcile_component_evidence(
         scope,
         source,
         observation,
         resource,
         payload,
         current_snapshot?
       ) do
    complete_snapshot? =
      complete_component_snapshot?(source, observation, payload, current_snapshot?)

    components =
      case Map.get(payload, "components") do
        components when is_list(components) -> components
        _absent_or_invalid -> []
      end

    component_attrs =
      components
      |> Enum.filter(&supported_component?/1)
      |> Enum.map(&component_evidence_attrs/1)

    module_identity_frequencies =
      component_attrs
      |> Enum.filter(&(&1["kind"] == "module"))
      |> Enum.frequencies_by(& &1["source_local_id"])

    module_position_frequencies =
      component_attrs
      |> Enum.filter(&(&1["kind"] == "module"))
      |> Enum.frequencies_by(&module_position_identity_key/1)

    component_attrs =
      Enum.reject(component_attrs, fn
        %{"kind" => "module", "source_local_id" => source_local_id} = module ->
          module_identity_frequencies[source_local_id] > 1 or
            module_position_frequencies[module_position_identity_key(module)] > 1

        _component ->
          false
      end)

    position_frequencies =
      component_attrs
      |> Enum.map(&position_identity_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    Enum.each(component_attrs, fn attrs ->
      position_key = position_identity_key(attrs)
      allow_position_match? = not is_nil(position_key) and position_frequencies[position_key] == 1

      existing =
        Repo.get_by(ComponentEvidence,
          organization_id: scope.organization_id,
          observation_id: observation.id,
          kind: attrs["kind"],
          source_local_id: attrs["source_local_id"]
        )

      evidence =
        existing ||
          case Inventory.create_component_evidence(
                 scope,
                 source.id,
                 observation.id,
                 resource.id,
                 attrs
               ) do
            {:ok, evidence} -> evidence
          end

      if evidence.kind in @canonical_component_kinds do
        reconcile_actual_component(scope, evidence, allow_position_match?)
      end
    end)

    Catalog.reconcile_component_findings(scope, observation, resource,
      component_snapshot_complete?: complete_snapshot?,
      component_snapshot_current?: current_snapshot?
    )
  end

  defp complete_component_snapshot?(source, observation, payload, current_snapshot?) do
    current_snapshot? and source.metadata["component_snapshot_policy"] == "complete" and
      components_declared_complete?(observation.payload) and
      is_list(Map.get(payload, "components"))
  end

  defp components_declared_complete?(%{
         "section_completeness" => %{"components" => true}
       }),
       do: true

  defp components_declared_complete?(_payload), do: false

  defp reconcile_actual_component(scope, evidence, allow_position_match?) do
    case Repo.get_by(ActualComponentEvidenceMatch,
           organization_id: scope.organization_id,
           component_evidence_id: evidence.id
         ) do
      nil ->
        case match_actual_component(scope.organization_id, evidence, allow_position_match?) do
          {:ok, component, strategy} ->
            put_actual_component_evidence_match(scope, component, evidence, strategy)
            update_actual_component(component, evidence)

          :none ->
            component = create_actual_component(scope, evidence)
            put_actual_component_evidence_match(scope, component, evidence, "discovered")

          :ambiguous ->
            :ok
        end

      _existing_match ->
        :ok
    end
  end

  defp match_actual_component(organization_id, evidence, allow_position_match?) do
    [
      {"serial_number", serial_component_matches(organization_id, evidence)},
      {"provider_id", provider_component_matches(organization_id, evidence)},
      {"position_part_number",
       position_component_matches(organization_id, evidence, allow_position_match?)}
    ]
    |> Enum.find_value(:none, fn
      {_strategy, []} -> false
      {strategy, [component]} -> {:ok, component, strategy}
      {_strategy, _ambiguous} -> :ambiguous
    end)
  end

  defp serial_component_matches(_organization_id, %{serial_number: nil}), do: []

  defp serial_component_matches(organization_id, evidence) do
    ActualComponent
    |> actual_component_scope(organization_id, evidence)
    |> where(
      [component],
      fragment("lower(?)", component.serial_number) == ^String.downcase(evidence.serial_number)
    )
    |> Repo.all()
  end

  defp provider_component_matches(organization_id, evidence) do
    ActualComponent
    |> actual_component_scope(organization_id, evidence)
    |> join(:inner, [component], match in ActualComponentEvidenceMatch,
      on: match.actual_component_id == component.id
    )
    |> join(:inner, [_component, match], prior in ComponentEvidence,
      on: prior.id == match.component_evidence_id
    )
    |> where(
      [_component, _match, prior],
      prior.source_id == ^evidence.source_id and
        prior.kind == ^evidence.kind and
        prior.source_local_id == ^evidence.source_local_id
    )
    |> distinct(true)
    |> Repo.all()
  end

  defp position_component_matches(_organization_id, _evidence, false), do: []
  defp position_component_matches(_organization_id, %{part_number: nil}, true), do: []

  defp position_component_matches(organization_id, evidence, true) do
    position = evidence.slot || evidence.path

    if position do
      ActualComponent
      |> actual_component_scope(organization_id, evidence)
      |> where(
        [component],
        fragment("lower(?)", component.part_number) == ^String.downcase(evidence.part_number)
      )
      |> position_match(evidence.slot, position)
      |> Repo.all()
    else
      []
    end
  end

  defp position_match(query, nil, path) do
    where(query, [component], fragment("lower(?)", component.path) == ^String.downcase(path))
  end

  defp position_match(query, _slot, slot) do
    where(query, [component], fragment("lower(?)", component.slot) == ^String.downcase(slot))
  end

  defp position_identity_key(attrs) do
    position = attrs["slot"] || attrs["path"]
    part_number = attrs["part_number"]

    if position && part_number do
      {attrs["kind"], String.downcase(position), String.downcase(part_number)}
    end
  end

  defp module_position_identity_key(module) do
    module
    |> then(&(&1["slot"] || &1["path"]))
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, " ")
    |> String.trim()
  end

  defp actual_component_scope(query, organization_id, evidence) do
    where(
      query,
      [component],
      component.organization_id == ^organization_id and
        component.owner_resource_id == ^evidence.resource_id and
        component.kind == ^evidence.kind
    )
  end

  defp create_actual_component(scope, evidence) do
    %ActualComponent{
      organization_id: scope.organization_id,
      owner_resource_id: evidence.resource_id
    }
    |> ActualComponent.changeset(actual_component_attrs(evidence, nil))
    |> Repo.insert!()
  end

  defp update_actual_component(component, evidence) do
    if DateTime.before?(evidence.observed_at, component.last_observed_at) do
      if DateTime.before?(evidence.observed_at, component.first_observed_at) do
        component
        |> ActualComponent.changeset(%{first_observed_at: evidence.observed_at})
        |> Repo.update!()
      else
        component
      end
    else
      component
      |> ActualComponent.changeset(actual_component_attrs(evidence, component))
      |> Repo.update!()
    end
  end

  defp actual_component_attrs(evidence, component) do
    canonical_fields =
      Map.new(~w(name model slot path serial_number part_number)a, fn field ->
        {field, Map.get(evidence, field) || actual_component_field(component, field)}
      end)

    Map.merge(canonical_fields, %{
      kind: evidence.kind,
      status: "present",
      attributes:
        Map.merge(actual_component_field(component, :attributes) || %{}, evidence.attributes),
      metadata:
        Map.merge(actual_component_field(component, :metadata) || %{}, %{
          "last_source_id" => evidence.source_id,
          "last_observation_id" => evidence.observation_id
        }),
      first_observed_at:
        actual_component_field(component, :first_observed_at) || evidence.observed_at,
      last_observed_at: evidence.observed_at
    })
  end

  defp actual_component_field(nil, _field), do: nil
  defp actual_component_field(component, field), do: Map.fetch!(component, field)

  defp put_actual_component_evidence_match(scope, component, evidence, strategy) do
    %ActualComponentEvidenceMatch{
      organization_id: scope.organization_id,
      owner_resource_id: evidence.resource_id,
      actual_component_id: component.id,
      component_evidence_id: evidence.id
    }
    |> ActualComponentEvidenceMatch.changeset(%{match_strategy: strategy})
    |> Repo.insert!()
  end

  defp supported_component?(%{"kind" => kind} = component) when kind in ~w(cpu memory disk) do
    not is_nil(component_source_local_id(component))
  end

  defp supported_component?(%{"kind" => "module"} = component) do
    not is_nil(module_source_local_id(component)) and not is_nil(module_position(component))
  end

  defp supported_component?(_component), do: false

  defp component_evidence_attrs(component) do
    known_fields =
      ~w(kind source_local_id id name model slot path serial_number part_number metadata)

    %{
      "kind" => component["kind"],
      "source_local_id" => component_source_local_id(component),
      "name" => optional_component_string(component["name"]),
      "model" => optional_component_string(component["model"]),
      "slot" => optional_component_string(component["slot"]),
      "path" => optional_component_string(component["path"]),
      "serial_number" => optional_component_string(component["serial_number"]),
      "part_number" => optional_component_string(component["part_number"]),
      "attributes" => Map.drop(component, known_fields),
      "raw_metadata" => component_metadata(component)
    }
  end

  defp component_source_local_id(%{"kind" => "module"} = component),
    do: module_source_local_id(component)

  defp component_source_local_id(component) do
    [
      component["source_local_id"],
      component["id"],
      component["serial_number"],
      component["slot"],
      component["path"],
      component["name"],
      component["device"],
      singleton_or_named_component_id(component)
    ]
    |> Enum.find_value(&optional_component_string/1)
  end

  defp module_source_local_id(component) do
    [component["source_local_id"], component["id"], component["serial_number"]]
    |> Enum.find_value(&optional_component_string/1)
  end

  defp module_position(component) do
    optional_component_string(component["slot"]) || optional_component_string(component["path"])
  end

  defp singleton_or_named_component_id(%{"kind" => kind}) when kind in ~w(cpu memory), do: kind

  defp singleton_or_named_component_id(%{"kind" => "disk"} = component) do
    component["name"] || component["path"] || component["device"]
  end

  defp optional_component_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed when byte_size(trimmed) > 255 -> nil
      trimmed -> trimmed
    end
  end

  defp optional_component_string(_value), do: nil

  defp component_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp component_metadata(_component), do: %{}

  defp reconcile_host(scope, source, observation, resource, payload, overrides) do
    identifiers = Map.get(payload, "identifiers", %{})

    attrs =
      payload
      |> Map.get("attributes", %{})
      |> Map.take(@host_fields)
      |> Map.put_new("hostname", single_identifier(identifiers, "hostname"))
      |> Map.put_new("fqdn", single_identifier(identifiers, "fqdn"))
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()
      |> normalize_host_attrs()

    host = Repo.get_by(Host, organization_id: scope.organization_id, resource_id: resource.id)

    if host do
      {changes, owners} =
        reconcile_fields(
          reconciliation_context(scope, source, observation, resource, overrides),
          host,
          attrs,
          @host_fields,
          "host",
          host.metadata
        )

      metadata = put_field_owners(host.metadata, owners)

      if changes != %{} or metadata != host.metadata do
        {:ok, _host} =
          host |> Host.changeset(Map.put(changes, "metadata", metadata)) |> Repo.update()
      end
    else
      {attrs, owners} =
        initial_fields(
          scope,
          source,
          observation,
          resource,
          attrs,
          "host",
          overrides,
          %{}
        )

      {:ok, _host} =
        Inventory.create_host(
          scope,
          resource.id,
          Map.put(attrs, "metadata", put_field_owners(%{}, owners))
        )
    end
  end

  defp reconcile_interface(
         scope,
         source,
         observation,
         resource,
         attrs,
         overrides,
         allow_new_rows?
       ) do
    name = attrs |> Map.fetch!("name") |> String.trim()

    interface =
      Repo.get_by(Interface,
        organization_id: scope.organization_id,
        resource_id: resource.id,
        name: name
      )

    if interface || allow_new_rows? do
      context = reconciliation_context(scope, source, observation, resource, overrides)

      do_reconcile_interface(
        context,
        attrs,
        allow_new_rows?,
        name,
        interface
      )
    end
  end

  defp do_reconcile_interface(
         context,
         attrs,
         allow_new_rows?,
         name,
         interface
       ) do
    %{scope: scope, source: source, observation: observation, resource: resource} = context
    overrides = context.overrides

    reported_attrs =
      attrs
      |> Map.take(@interface_fields)
      |> Map.put("name", name)
      |> cast_mac_address()

    create_attrs =
      reported_attrs
      |> Map.put_new("kind", "ethernet")
      |> Map.put_new("status", "unknown")

    interface =
      if interface do
        {changes, owners} =
          reconcile_fields(
            context,
            interface,
            reported_attrs,
            @interface_fields,
            "interfaces.#{name}",
            interface.metadata
          )

        metadata = put_field_owners(interface.metadata, owners)

        if changes != %{} or metadata != interface.metadata do
          {:ok, interface} =
            interface
            |> Interface.changeset(Map.put(changes, "metadata", metadata))
            |> Repo.update()

          interface
        else
          interface
        end
      else
        {accepted_attrs, owners} =
          initial_fields(
            scope,
            source,
            observation,
            resource,
            create_attrs,
            "interfaces.#{name}",
            overrides,
            %{"name" => name, "kind" => "ethernet", "status" => "unknown"}
          )

        {:ok, interface} =
          Inventory.create_interface(
            scope,
            resource.id,
            Map.put(
              accepted_attrs,
              "metadata",
              put_field_owners(%{}, owners)
            )
          )

        interface
      end

    put_interface_evidence(scope, source, observation, interface, create_attrs, attrs)

    attrs
    |> Map.get("addresses", [])
    |> Enum.each(
      &reconcile_address(
        scope,
        source,
        observation,
        resource,
        interface,
        &1,
        overrides,
        allow_new_rows?
      )
    )
  end

  defp put_interface_evidence(scope, source, observation, interface, canonical_attrs, raw_attrs) do
    existing =
      Repo.get_by(InterfaceEvidence,
        organization_id: scope.organization_id,
        observation_id: observation.id,
        interface_id: interface.id
      )

    unless existing do
      evidence_attrs =
        raw_attrs
        |> Map.take(@interface_fields)
        |> Map.put_new("kind", canonical_attrs["kind"])
        |> Map.put_new("status", canonical_attrs["status"])
        |> cast_mac_address()
        |> Map.put("metadata", Map.get(raw_attrs, "metadata", %{}))

      catalog_match = catalog_interface_match(scope, interface, evidence_attrs)

      {:ok, _evidence} =
        Inventory.create_interface_evidence(
          scope,
          source.id,
          observation.id,
          interface.id,
          evidence_attrs,
          catalog_match
        )
    end
  end

  defp catalog_interface_match(scope, interface, evidence_attrs) do
    expectations =
      scope
      |> Catalog.list_expected_components(interface.resource_id)
      |> Enum.filter(fn expected ->
        expected.kind == "interface" and not expected.suppressed and
          not is_nil(expected.component_template_id)
      end)

    case evidence_attrs["mac_address"] do
      %Postgrex.MACADDR{} = reported_mac ->
        match_interface_by_mac(expectations, reported_mac, interface.name)

      _missing_mac ->
        match_interface_by_name(expectations, interface.name)
    end
  end

  defp match_interface_by_mac(expectations, reported_mac, reported_name) do
    case Enum.filter(expectations, &expected_interface_mac_matches?(&1, reported_mac)) do
      [] ->
        expectations
        |> Enum.filter(&expected_interface_mac_compatible?(&1, reported_mac))
        |> match_interface_by_name(reported_name)

      matches ->
        catalog_interface_match_result(matches, "mac_address")
    end
  end

  defp match_interface_by_name(expectations, reported_name) do
    normalized_name = normalize_interface_template_value(reported_name)

    expectations
    |> Enum.filter(fn expected ->
      Enum.any?([expected.position, expected.name], fn candidate ->
        is_binary(candidate) and normalize_interface_template_value(candidate) == normalized_name
      end)
    end)
    |> catalog_interface_match_result("name")
  end

  defp catalog_interface_match_result([], _strategy), do: %{status: "unmatched"}

  defp catalog_interface_match_result([expected], strategy) do
    %{
      status: "matched",
      strategy: strategy,
      component_template_id: expected.component_template_id
    }
  end

  defp catalog_interface_match_result(_ambiguous, _strategy), do: %{status: "ambiguous"}

  defp expected_interface_mac_matches?(expected, reported_mac) do
    MacAddress.cast(expected.attributes["mac_address"]) == {:ok, reported_mac}
  end

  defp expected_interface_mac_compatible?(expected, reported_mac) do
    case MacAddress.cast(expected.attributes["mac_address"]) do
      {:ok, expected_mac} -> expected_mac == reported_mac
      :error -> true
    end
  end

  defp normalize_interface_template_value(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, " ")
    |> String.trim()
  end

  defp reconcile_address(
         scope,
         source,
         observation,
         resource,
         interface,
         raw_address,
         overrides,
         allow_new_rows?
       ) do
    attrs = normalize_address(raw_address)
    {:ok, cast_address} = Inet.cast(attrs["address"])

    address =
      scope
      |> Inventory.list_addresses(interface.id)
      |> Enum.find(&same_inet?(&1.address, cast_address))

    if address || allow_new_rows? do
      address =
        reconcile_canonical_address(
          scope,
          source,
          observation,
          resource,
          interface,
          address,
          attrs,
          overrides
        )

      existing =
        Repo.get_by(AddressEvidence,
          organization_id: scope.organization_id,
          observation_id: observation.id,
          address_id: address.id
        )

      unless existing do
        {:ok, _evidence} =
          Inventory.create_address_evidence(
            scope,
            source.id,
            observation.id,
            address.id,
            Map.take(attrs, ~w(address scope metadata))
          )
      end
    end
  end

  defp reconcile_canonical_address(
         scope,
         source,
         observation,
         resource,
         interface,
         nil,
         attrs,
         overrides
       ) do
    path = "addresses.#{attrs["address"]}"

    {mutable_attrs, owners} =
      initial_fields(
        scope,
        source,
        observation,
        resource,
        Map.take(attrs, ~w(scope)),
        path,
        overrides,
        %{}
      )

    create_attrs =
      attrs
      |> Map.take(~w(address kind))
      |> Map.merge(mutable_attrs)
      |> Map.put(
        "metadata",
        %{}
        |> put_field_owners(owners)
        |> put_address_presence(source, observation, true)
      )

    case Inventory.create_address(scope, interface.id, create_attrs) do
      {:ok, created} -> created
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp reconcile_canonical_address(
         scope,
         source,
         observation,
         resource,
         _interface,
         %Address{} = address,
         attrs,
         overrides
       ) do
    {changes, owners} =
      reconcile_fields(
        reconciliation_context(scope, source, observation, resource, overrides),
        address,
        Map.take(attrs, ~w(scope)),
        ~w(scope),
        "addresses.#{attrs["address"]}",
        address.metadata
      )

    metadata =
      address.metadata
      |> put_field_owners(owners)
      |> put_address_presence(source, observation, true)

    record_address_presence_update(
      scope,
      source,
      observation,
      resource,
      address,
      metadata
    )

    if changes != %{} or metadata != address.metadata do
      {:ok, address} =
        address
        |> Address.changeset(Map.put(changes, "metadata", metadata))
        |> Repo.update()

      address
    else
      address
    end
  end

  defp initial_fields(
         scope,
         source,
         observation,
         resource,
         incoming,
         path,
         overrides,
         defaults
       ) do
    Enum.reduce(incoming, {defaults, %{}}, fn {field, value}, {accepted, owners} ->
      field_path = "#{path}.#{field}"
      override = Map.get(overrides, field_path) || Map.get(overrides, field)

      maybe_record_desired_conflict(
        scope,
        source,
        observation,
        resource,
        field_path,
        desired_value(resource.spec, path, field),
        value
      )

      context = reconciliation_context(scope, source, observation, resource, overrides)
      accept_initial_field(context, {accepted, owners}, path, field, value, override)
    end)
  end

  defp accept_initial_field(context, {accepted, owners}, _path, field, value, nil) do
    {Map.put(accepted, field, value),
     Map.put(owners, field, owner(context.source, context.observation))}
  end

  defp accept_initial_field(context, {accepted, owners}, path, field, value, override) do
    manual_value = normalize_override_value(path, field, override_value(override.value))
    field_path = "#{path}.#{field}"

    if manual_value != value do
      record_conflict(context, field_path, manual_value, value, "manual_override")
    end

    {Map.put(accepted, field, manual_value), Map.put(owners, field, manual_owner(override))}
  end

  defp reconcile_network_omissions(
         scope,
         source,
         observation,
         resource,
         reported_interfaces,
         overrides
       ) do
    reported_names = MapSet.new(reported_interfaces, &(&1 |> Map.fetch!("name") |> String.trim()))

    authoritative_address_names =
      reported_interfaces
      |> Enum.filter(&Map.has_key?(&1, "addresses"))
      |> MapSet.new(&(&1 |> Map.fetch!("name") |> String.trim()))

    reported_addresses =
      reported_interfaces
      |> Enum.flat_map(fn interface ->
        name = interface |> Map.fetch!("name") |> String.trim()

        Enum.map(Map.get(interface, "addresses", []), fn address ->
          attrs = normalize_address(address)
          {:ok, cast_address} = Inet.cast(attrs["address"])
          {name, format_inet(cast_address)}
        end)
      end)
      |> MapSet.new()

    scope
    |> Inventory.list_interfaces(resource.id)
    |> Enum.each(fn interface ->
      if source_reported_interface?(scope, source, interface) and
           not MapSet.member?(reported_names, interface.name) do
        mark_interface_not_present(
          scope,
          source,
          observation,
          resource,
          interface,
          overrides
        )
      end

      context = reconciliation_context(scope, source, observation, resource, overrides)

      Enum.each(Inventory.list_addresses(scope, interface.id), fn address ->
        reconcile_address_omission(
          context,
          interface,
          address,
          reported_names,
          authoritative_address_names,
          reported_addresses
        )
      end)
    end)
  end

  defp reconcile_address_omission(
         context,
         interface,
         address,
         names,
         authoritative_names,
         addresses
       ) do
    authoritative? =
      not MapSet.member?(names, interface.name) or
        MapSet.member?(authoritative_names, interface.name)

    address_key = {interface.name, format_inet(address.address)}

    if authoritative? and source_reported_address?(context.scope, context.source, address) and
         not MapSet.member?(addresses, address_key) do
      metadata =
        put_address_presence(address.metadata, context.source, context.observation, false)

      record_address_presence_update(
        context.scope,
        context.source,
        context.observation,
        context.resource,
        address,
        metadata
      )

      if metadata != address.metadata do
        {:ok, _address} = address |> Address.changeset(%{metadata: metadata}) |> Repo.update()
      end
    end
  end

  defp source_reported_interface?(scope, source, interface) do
    Repo.exists?(
      from evidence in InterfaceEvidence,
        where:
          evidence.organization_id == ^scope.organization_id and
            evidence.source_id == ^source.id and evidence.interface_id == ^interface.id
    )
  end

  defp source_reported_address?(scope, source, address) do
    Repo.exists?(
      from evidence in AddressEvidence,
        where:
          evidence.organization_id == ^scope.organization_id and
            evidence.source_id == ^source.id and evidence.address_id == ^address.id
    )
  end

  defp mark_interface_not_present(
         scope,
         source,
         observation,
         resource,
         interface,
         overrides
       ) do
    {changes, owners} =
      reconcile_fields(
        reconciliation_context(scope, source, observation, resource, overrides),
        interface,
        %{"status" => "not_present"},
        ~w(status),
        "interfaces.#{interface.name}",
        interface.metadata
      )

    metadata = put_field_owners(interface.metadata, owners)

    if changes != %{} or metadata != interface.metadata do
      {:ok, _interface} =
        interface
        |> Interface.changeset(Map.put(changes, "metadata", metadata))
        |> Repo.update()
    end
  end

  defp reconcile_fields(
         context,
         record,
         incoming,
         fields,
         path,
         metadata
       ) do
    owners = Map.get(metadata || %{}, "field_owners", %{})

    Enum.reduce(fields, {%{}, owners}, fn field, {changes, owners} ->
      if Map.has_key?(incoming, field) do
        reconcile_field(context, record, incoming, path, field, {changes, owners})
      else
        {changes, owners}
      end
    end)
  end

  defp reconcile_field(context, record, incoming, path, field, {changes, owners}) do
    incoming_value = Map.fetch!(incoming, field)
    current_value = Map.get(record, String.to_existing_atom(field))
    field_path = "#{path}.#{field}"
    override = Map.get(context.overrides, field_path) || Map.get(context.overrides, field)
    existing_owner = effective_owner(Map.get(owners, field), override)

    maybe_record_desired_conflict(
      context.scope,
      context.source,
      context.observation,
      context.resource,
      field_path,
      desired_value(context.resource.spec, path, field),
      incoming_value
    )

    cond do
      override ->
        reconcile_overridden_field(
          context,
          {changes, owners},
          path,
          field,
          current_value,
          incoming_value,
          override
        )

      source_wins?(context.source, context.observation, existing_owner, field_path) ->
        reconcile_winning_field(
          context,
          {changes, owners},
          field,
          field_path,
          current_value,
          incoming_value
        )

      current_value != incoming_value ->
        record_conflict(
          context,
          field_path,
          current_value,
          incoming_value,
          "lower_precedence_source"
        )

        {changes, owners}

      true ->
        {changes, owners}
    end
  end

  defp effective_owner(owner, nil) do
    if get_in(owner || %{}, ["source_kind"]) == "manual", do: nil, else: owner
  end

  defp effective_owner(owner, _override), do: owner

  defp reconcile_overridden_field(
         context,
         {changes, owners},
         path,
         field,
         current,
         incoming,
         override
       ) do
    value = normalize_override_value(path, field, override_value(override.value))
    field_path = "#{path}.#{field}"

    if value != incoming,
      do: record_conflict(context, field_path, value, incoming, "manual_override")

    if current != value, do: record_update(context, field_path, current, value)
    {Map.put(changes, field, value), Map.put(owners, field, manual_owner(override))}
  end

  defp reconcile_winning_field(context, {changes, owners}, field, field_path, current, incoming) do
    if current != nil and current != incoming and
         get_in(owners, [field, "source_id"]) != context.source.id do
      record_conflict(context, field_path, current, incoming, "source_disagreement")
    end

    if current != incoming, do: record_update(context, field_path, current, incoming)

    {Map.put(changes, field, incoming),
     Map.put(owners, field, owner(context.source, context.observation))}
  end

  defp source_wins?(_source, _observation, nil, _path), do: true

  defp source_wins?(source, observation, existing_owner, path) do
    incoming = {
      source_priority(source.kind, path),
      DateTime.to_unix(observation.observed_at, :microsecond),
      source.id,
      observation.id
    }

    existing = {
      source_priority(existing_owner["source_kind"], path),
      owner_observed_at(existing_owner),
      existing_owner["source_id"] || "",
      existing_owner["observation_id"] || ""
    }

    incoming >= existing
  end

  defp source_priority("manual", _path), do: 500
  defp source_priority("bmc", "host." <> field) when field in ~w(vendor model asset_tag), do: 400
  defp source_priority("switch_poller", "interfaces." <> _rest), do: 400
  defp source_priority("host_agent", _path), do: 300
  defp source_priority("vm_provider", _path), do: 200
  defp source_priority("bmc", _path), do: 100
  defp source_priority(_kind, _path), do: 0

  defp owner(source, observation) do
    %{
      "source_id" => source.id,
      "source_kind" => source.kind,
      "observed_at" => DateTime.to_iso8601(observation.observed_at),
      "observation_id" => observation.id
    }
  end

  defp manual_owner(override) do
    %{
      "source_kind" => "manual",
      "override_id" => override.id,
      "created_by_user_id" => override.created_by_user_id,
      "overridden_at" => DateTime.to_iso8601(override.inserted_at)
    }
  end

  defp owner_observed_at(%{"observed_at" => observed_at}) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> 0
    end
  end

  defp owner_observed_at(_owner), do: 0

  defp put_field_owners(metadata, owners), do: Map.put(metadata || %{}, "field_owners", owners)

  defp put_address_presence(metadata, source, observation, present?) do
    metadata = metadata || %{}

    if source_wins?(source, observation, metadata["presence_owner"], "addresses.presence") do
      metadata
      |> Map.put("present", present?)
      |> Map.put("presence_owner", owner(source, observation))
    else
      metadata
    end
  end

  defp record_address_presence_update(
         scope,
         source,
         observation,
         resource,
         address,
         metadata
       ) do
    old_present? = address.metadata["present"]
    new_present? = metadata["present"]

    if is_boolean(old_present?) and old_present? != new_present? do
      record_update(
        scope,
        source,
        observation,
        resource,
        "addresses.#{format_inet(address.address)}.present",
        old_present?,
        new_present?
      )
    end
  end

  defp maybe_record_desired_conflict(
         _scope,
         _source,
         _observation,
         _resource,
         _field,
         nil,
         _incoming
       ),
       do: :ok

  defp maybe_record_desired_conflict(
         scope,
         source,
         observation,
         resource,
         field,
         desired,
         incoming
       ) do
    if desired != incoming do
      record_conflict(
        scope,
        source,
        observation,
        resource,
        field,
        desired,
        incoming,
        "desired_state"
      )
    end
  end

  defp record_update(scope, source, observation, resource, field, old_value, new_value) do
    context = reconciliation_context(scope, source, observation, resource, %{})
    record_update(context, field, old_value, new_value)
  end

  defp record_update(context, field, old_value, new_value) do
    record_event(context, %{
      kind: "updated",
      field: field,
      old_value: old_value,
      new_value: new_value,
      metadata: %{}
    })
  end

  defp record_conflict(
         scope,
         source,
         observation,
         resource,
         field,
         canonical_value,
         observed_value,
         reason
       ) do
    context = reconciliation_context(scope, source, observation, resource, %{})
    record_conflict(context, field, canonical_value, observed_value, reason)
  end

  defp record_conflict(context, field, canonical_value, observed_value, reason) do
    record_event(context, %{
      kind: "conflict",
      field: field,
      old_value: canonical_value,
      new_value: observed_value,
      metadata: %{"reason" => reason}
    })
  end

  defp record_event(context, event_attrs) do
    %{scope: scope, source: source, observation: observation, resource: resource} = context

    %{kind: kind, field: field, old_value: old_value, new_value: new_value, metadata: metadata} =
      event_attrs

    query =
      from event in Renga.Inventory.ChangeEvent,
        where:
          event.organization_id == ^scope.organization_id and
            event.observation_id == ^observation.id and event.kind == ^kind and
            event.field == ^field

    query =
      case metadata do
        %{"reason" => reason} ->
          where(query, [event], fragment("?->>'reason' = ?", event.metadata, ^reason))

        _metadata ->
          query
      end

    exists? = Repo.exists?(query)

    unless exists? do
      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: kind,
          field: field,
          resource_id: resource.id,
          source_id: source.id,
          observation_id: observation.id,
          old_value: event_value(old_value),
          new_value: event_value(new_value),
          metadata: metadata,
          occurred_at: observation.observed_at
        })
    end
  end

  defp reconciliation_context(scope, source, observation, resource, overrides) do
    %{
      scope: scope,
      source: source,
      observation: observation,
      resource: resource,
      overrides: overrides
    }
  end

  defp desired_value(spec, "host", field) do
    get_in(spec, ["host", field]) || Map.get(spec, field)
  end

  defp desired_value(spec, path, field), do: get_in(spec, String.split(path, ".") ++ [field])

  defp override_value(%{"value" => value}), do: value
  defp override_value(%{value: value}), do: value
  defp override_value(value), do: value

  defp normalize_override_value("host", field, value)
       when field in ~w(hostname fqdn) and is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_override_value("interfaces." <> _name, "mac_address", value) do
    case MacAddress.cast(value) do
      {:ok, mac_address} -> mac_address
      :error -> value
    end
  end

  defp normalize_override_value(_path, _field, value), do: value

  defp event_value(value), do: ChangeEvent.audit_value(value)

  defp format_inet(%Postgrex.INET{address: address} = inet) do
    "#{address |> :inet.ntoa() |> to_string()}/#{inet_netmask(inet)}"
  end

  # Postgrex decodes an INET host mask as nil, while casting the equivalent
  # explicit /32 or /128 retains the integer. Treat both representations as
  # the same address so repeated observations remain idempotent.
  defp same_inet?(%Postgrex.INET{} = left, %Postgrex.INET{} = right) do
    left.address == right.address and inet_netmask(left) == inet_netmask(right)
  end

  defp inet_netmask(%Postgrex.INET{address: address, netmask: nil})
       when tuple_size(address) == 4,
       do: 32

  defp inet_netmask(%Postgrex.INET{address: address, netmask: nil})
       when tuple_size(address) == 8,
       do: 128

  defp inet_netmask(%Postgrex.INET{netmask: netmask}), do: netmask

  defp cast_mac_address(%{"mac_address" => mac_address} = attrs) do
    {:ok, cast_mac_address} = MacAddress.cast(mac_address)
    Map.put(attrs, "mac_address", cast_mac_address)
  end

  defp cast_mac_address(attrs), do: attrs

  defp normalize_host_attrs(attrs) do
    attrs
    |> normalize_name("hostname")
    |> normalize_name("fqdn")
  end

  defp single_identifier(identifiers, kind) do
    case Map.get(identifiers, kind) do
      value when is_binary(value) -> value
      [value] when is_binary(value) -> value
      _missing_or_multiple -> nil
    end
  end

  defp normalize_name(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) ->
        Map.put(attrs, field, value |> String.trim() |> String.downcase())

      _missing_or_nil ->
        attrs
    end
  end

  defp normalize_address(address) when is_binary(address) do
    %{"address" => address, "kind" => address_kind(address)}
  end

  defp normalize_address(%{} = address) do
    address
    |> Map.put_new("kind", address_kind(Map.fetch!(address, "address")))
    |> Map.put_new("metadata", %{})
  end

  defp address_kind(address) do
    if String.contains?(address, ":"), do: "ipv6", else: "ipv4"
  end

  defp resource_payload(%{"resources" => [resource]}), do: resource
end
