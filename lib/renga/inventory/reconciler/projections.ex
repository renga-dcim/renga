defmodule Renga.Inventory.Reconciler.Projections do
  @moduledoc """
  Reconciles host and network facts after resource identity is resolved.

  Canonical rows retain deterministic per-field ownership in metadata while
  observation-scoped evidence remains available for source comparison.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
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
          scope,
          source,
          observation,
          resource,
          host,
          attrs,
          @host_fields,
          "host",
          host.metadata,
          overrides
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
      do_reconcile_interface(
        scope,
        source,
        observation,
        resource,
        attrs,
        overrides,
        allow_new_rows?,
        name,
        interface
      )
    end
  end

  defp do_reconcile_interface(
         scope,
         source,
         observation,
         resource,
         attrs,
         overrides,
         allow_new_rows?,
         name,
         interface
       ) do
    canonical_attrs =
      attrs
      |> Map.take(@interface_fields)
      |> Map.put("name", name)
      |> Map.put_new("kind", "ethernet")
      |> Map.put_new("status", "unknown")
      |> cast_mac_address()

    interface =
      if interface do
        {changes, owners} =
          reconcile_fields(
            scope,
            source,
            observation,
            resource,
            interface,
            canonical_attrs,
            @interface_fields,
            "interfaces.#{name}",
            interface.metadata,
            overrides
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
            canonical_attrs,
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

    put_interface_evidence(scope, source, observation, interface, canonical_attrs, attrs)

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

      {:ok, _evidence} =
        Inventory.create_interface_evidence(
          scope,
          source.id,
          observation.id,
          interface.id,
          evidence_attrs
        )
    end
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
      |> Enum.find(&(&1.address == cast_address))

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
        scope,
        source,
        observation,
        resource,
        address,
        Map.take(attrs, ~w(scope)),
        ~w(scope),
        "addresses.#{attrs["address"]}",
        address.metadata,
        overrides
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

      if override do
        manual_value = normalize_override_value(path, field, override_value(override.value))

        if manual_value != value do
          record_conflict(
            scope,
            source,
            observation,
            resource,
            field_path,
            manual_value,
            value,
            "manual_override"
          )
        end

        {Map.put(accepted, field, manual_value), Map.put(owners, field, manual_owner(override))}
      else
        {Map.put(accepted, field, value), Map.put(owners, field, owner(source, observation))}
      end
    end)
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

      scope
      |> Inventory.list_addresses(interface.id)
      |> Enum.each(fn address ->
        address_key = {interface.name, format_inet(address.address)}

        addresses_authoritative? =
          not MapSet.member?(reported_names, interface.name) or
            MapSet.member?(authoritative_address_names, interface.name)

        if addresses_authoritative? and source_reported_address?(scope, source, address) and
             not MapSet.member?(reported_addresses, address_key) do
          metadata = put_address_presence(address.metadata, source, observation, false)

          record_address_presence_update(
            scope,
            source,
            observation,
            resource,
            address,
            metadata
          )

          if metadata != address.metadata do
            {:ok, _address} = address |> Address.changeset(%{metadata: metadata}) |> Repo.update()
          end
        end
      end)
    end)
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
        scope,
        source,
        observation,
        resource,
        interface,
        %{"status" => "not_present"},
        ~w(status),
        "interfaces.#{interface.name}",
        interface.metadata,
        overrides
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
         scope,
         source,
         observation,
         resource,
         record,
         incoming,
         fields,
         path,
         metadata,
         overrides
       ) do
    owners = Map.get(metadata || %{}, "field_owners", %{})

    Enum.reduce(fields, {%{}, owners}, fn field, {changes, owners} ->
      if Map.has_key?(incoming, field) do
        incoming_value = Map.fetch!(incoming, field)
        current_value = Map.get(record, String.to_existing_atom(field))
        field_path = "#{path}.#{field}"
        override = Map.get(overrides, field_path) || Map.get(overrides, field)
        existing_owner = Map.get(owners, field)

        existing_owner =
          if is_nil(override) && get_in(existing_owner || %{}, ["source_kind"]) == "manual" do
            nil
          else
            existing_owner
          end

        maybe_record_desired_conflict(
          scope,
          source,
          observation,
          resource,
          field_path,
          desired_value(resource.spec, path, field),
          incoming_value
        )

        cond do
          override ->
            manual_value = normalize_override_value(path, field, override_value(override.value))

            if manual_value != incoming_value do
              record_conflict(
                scope,
                source,
                observation,
                resource,
                field_path,
                manual_value,
                incoming_value,
                "manual_override"
              )
            end

            if current_value != manual_value do
              record_update(
                scope,
                source,
                observation,
                resource,
                field_path,
                current_value,
                manual_value
              )
            end

            {Map.put(changes, field, manual_value),
             Map.put(owners, field, manual_owner(override))}

          source_wins?(source, observation, existing_owner, field_path) ->
            if current_value != nil and current_value != incoming_value and
                 get_in(owners, [field, "source_id"]) != source.id do
              record_conflict(
                scope,
                source,
                observation,
                resource,
                field_path,
                current_value,
                incoming_value,
                "source_disagreement"
              )
            end

            if current_value != incoming_value do
              record_update(
                scope,
                source,
                observation,
                resource,
                field_path,
                current_value,
                incoming_value
              )
            end

            {Map.put(changes, field, incoming_value),
             Map.put(owners, field, owner(source, observation))}

          current_value != incoming_value ->
            record_conflict(
              scope,
              source,
              observation,
              resource,
              field_path,
              current_value,
              incoming_value,
              "lower_precedence_source"
            )

            {changes, owners}

          true ->
            {changes, owners}
        end
      else
        {changes, owners}
      end
    end)
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
    record_event(
      scope,
      source,
      observation,
      resource,
      "updated",
      field,
      old_value,
      new_value,
      %{}
    )
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
    record_event(
      scope,
      source,
      observation,
      resource,
      "conflict",
      field,
      canonical_value,
      observed_value,
      %{"reason" => reason}
    )
  end

  defp record_event(
         scope,
         source,
         observation,
         resource,
         kind,
         field,
         old_value,
         new_value,
         metadata
       ) do
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

  defp event_value(nil), do: nil
  defp event_value(%Postgrex.MACADDR{address: address}), do: %{"value" => format_mac(address)}
  defp event_value(%Postgrex.INET{} = address), do: %{"value" => format_inet(address)}
  defp event_value(value) when is_map(value), do: value

  defp event_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: %{"value" => value}

  defp event_value(value), do: %{"value" => inspect(value)}

  defp format_mac(address) do
    address
    |> Tuple.to_list()
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: nil}) do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{address |> :inet.ntoa() |> to_string()}/#{netmask}"
  end

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
