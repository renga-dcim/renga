defmodule Renga.IPAM.RoutingDomains do
  @moduledoc """
  Routing-domain claims and their resolution (RFD 4, "Observation
  correlation").

  A collector reports an interface's routing domain as a source-local key,
  optionally with a route distinguisher, in the interface's
  `"routing_domain"` field:

    * an object (`%{"key" => "blue", "route_distinguisher" => "65000:1"}`)
      claims the interface is in that domain;
    * `null` withdraws the source's claim: the interface is in no routing
      domain as far as that source knows, so it is global;
    * an absent field says nothing, and earlier claims stand.

  Claims are observation-linked evidence. Each source has at most one active
  claim per interface; a newer report replaces or withdraws it, and a late
  replay of an older report is stored already stale.

  The current claim of an interface is the newest active claim, preferring
  sources whose claims are authoritative. Its key resolves to a namespace,
  first match wins:

    1. an explicit organization mapping for that source and key (to a VRF
       or to the global table);
    2. a VRF whose route distinguisher equals the reported one;
    3. a VRF whose name equals the key, ignoring case;
    4. the key `default`, reserved for the global table;

  and otherwise the claim is `unmapped`, which is never silently global.
  `interface_routing_domains` holds the result; `refresh/1` rebuilds it
  whenever claims, mappings, VRFs, or source authority change. An interface
  with no claim has no row and is in the global table.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.IPAM.InterfaceRoutingDomain
  alias Renga.IPAM.RoutingDomainEvidence
  alias Renga.IPAM.RoutingDomainMapping
  alias Renga.IPAM.Vrf
  alias Renga.Repo

  ## Ingestion

  @doc """
  Records the routing-domain claims in one observation of one resource's
  interfaces, then refreshes the organization's resolved domains. Runs in
  the caller's reconciliation transaction.
  """
  def record_claims(
        organization_id,
        %Source{} = source,
        %Observation{} = observation,
        resource_id,
        reported_interfaces
      ) do
    claims = Enum.filter(reported_interfaces, &Map.has_key?(&1, "routing_domain"))

    if claims != [] do
      interfaces =
        Interface
        |> where([i], i.organization_id == ^organization_id and i.resource_id == ^resource_id)
        |> Repo.all()
        |> Map.new(&{&1.name, &1})

      for reported <- claims,
          interface = Map.get(interfaces, String.trim(reported["name"])),
          not is_nil(interface),
          not recorded?(organization_id, observation, interface) do
        record_claim(organization_id, source, observation, interface, reported["routing_domain"])
      end

      {:ok, :ok} = refresh(organization_id)
    end

    :ok
  end

  defp recorded?(organization_id, observation, interface) do
    Repo.exists?(
      from evidence in RoutingDomainEvidence,
        where:
          evidence.organization_id == ^organization_id and
            evidence.observation_id == ^observation.id and evidence.interface_id == ^interface.id
    )
  end

  # A replay of an older report is history; a current one supersedes every
  # earlier claim of the same source about the interface. A withdrawal is
  # stored inactive, as the watermark that keeps older claims from coming
  # back.
  defp record_claim(organization_id, source, observation, interface, claim) do
    {key, route_distinguisher, metadata} = claim_attrs(claim)
    newer = newer_report_at(organization_id, source.id, interface.id, observation)

    if is_nil(newer),
      do: supersede(organization_id, source, interface, observation)

    %RoutingDomainEvidence{
      organization_id: organization_id,
      interface_id: interface.id,
      source_id: source.id,
      observation_id: observation.id
    }
    |> RoutingDomainEvidence.changeset(%{
      source_local_key: key,
      route_distinguisher: route_distinguisher,
      metadata: metadata,
      observed_at: observation.observed_at,
      stale_at: newer || if(is_nil(key), do: observation.observed_at)
    })
    |> Repo.insert!()
  end

  defp supersede(organization_id, source, interface, observation) do
    RoutingDomainEvidence
    |> where([e], e.organization_id == ^organization_id and e.source_id == ^source.id)
    |> where([e], e.interface_id == ^interface.id and is_nil(e.stale_at))
    |> where(
      [e],
      e.observed_at < ^observation.observed_at or
        (e.observed_at == ^observation.observed_at and e.observation_id < ^observation.id)
    )
    |> Repo.update_all(set: [stale_at: observation.observed_at])
  end

  defp claim_attrs(nil), do: {nil, nil, %{}}

  defp claim_attrs(%{} = claim) do
    {String.trim(claim["key"]), blank_to_nil(claim["route_distinguisher"]),
     claim |> Map.get("metadata", %{}) |> then(&if(is_map(&1), do: &1, else: %{}))}
  end

  # Match inventory freshness: observation identity breaks millisecond ties,
  # including withdrawals, independently of reconciliation/replay order.
  defp newer_report_at(organization_id, source_id, interface_id, observation) do
    RoutingDomainEvidence
    |> where([e], e.organization_id == ^organization_id and e.source_id == ^source_id)
    |> where([e], e.interface_id == ^interface_id)
    |> where(
      [e],
      e.observed_at > ^observation.observed_at or
        (e.observed_at == ^observation.observed_at and e.observation_id > ^observation.id)
    )
    |> select([e], min(e.observed_at))
    |> Repo.one()
  end

  ## Resolution

  @doc """
  Rebuilds every interface's resolved routing domain in the organization
  from active claims, mappings, VRFs, and source authority. Safe inside a
  caller's transaction.
  """
  def refresh(organization_id) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(organization_id)
      resolver = resolver(organization_id)
      now = Renga.Time.utc_now_ms()

      rows =
        organization_id
        |> current_claims()
        |> Enum.map(fn claim ->
          {resolution, vrf_id} = resolver.(claim)

          %{
            interface_id: claim.interface_id,
            organization_id: organization_id,
            evidence_id: claim.id,
            source_id: claim.source_id,
            source_local_key: claim.source_local_key,
            route_distinguisher: claim.route_distinguisher,
            authoritative: claim.authoritative,
            resolution: resolution,
            vrf_id: vrf_id,
            observed_at: claim.observed_at,
            inserted_at: now,
            updated_at: now
          }
        end)

      claimed = Enum.map(rows, & &1.interface_id)

      InterfaceRoutingDomain
      |> where([d], d.organization_id == ^organization_id and d.interface_id not in ^claimed)
      |> Repo.delete_all()

      rows
      |> Enum.chunk_every(1_000)
      |> Enum.each(fn chunk ->
        Repo.insert_all(InterfaceRoutingDomain, chunk,
          on_conflict:
            {:replace,
             [
               :evidence_id,
               :source_id,
               :source_local_key,
               :route_distinguisher,
               :authoritative,
               :resolution,
               :vrf_id,
               :observed_at,
               :updated_at
             ]},
          conflict_target: [:interface_id]
        )
      end)

      :ok
    end)
  end

  # The newest active claim per interface, authoritative sources first.
  defp current_claims(organization_id) do
    from(evidence in RoutingDomainEvidence,
      join: source in Source,
      on: source.id == evidence.source_id,
      where: evidence.organization_id == ^organization_id and is_nil(evidence.stale_at),
      distinct: evidence.interface_id,
      order_by: [
        asc: evidence.interface_id,
        desc: source.authoritative_routing_domains,
        desc: evidence.observed_at,
        desc: evidence.observation_id
      ],
      select: %{
        id: evidence.id,
        interface_id: evidence.interface_id,
        source_id: evidence.source_id,
        source_local_key: evidence.source_local_key,
        route_distinguisher: evidence.route_distinguisher,
        observed_at: evidence.observed_at,
        authoritative: source.authoritative_routing_domains
      }
    )
    |> Repo.all()
  end

  defp resolver(organization_id) do
    mappings =
      RoutingDomainMapping
      |> where([m], m.organization_id == ^organization_id)
      |> Repo.all()
      |> Map.new(&{{&1.source_id, String.downcase(&1.source_local_key)}, &1.vrf_id})

    vrfs = Vrf |> where([v], v.organization_id == ^organization_id) |> Repo.all()
    by_rd = for %{route_distinguisher: rd} = vrf <- vrfs, rd, into: %{}, do: {rd, vrf.id}
    by_name = Map.new(vrfs, &{String.downcase(&1.name), &1.id})

    &resolve(&1, mappings, by_rd, by_name)
  end

  @doc false
  def resolve(claim, mappings, by_rd, by_name) do
    key = String.downcase(claim.source_local_key)

    cond do
      Map.has_key?(mappings, {claim.source_id, key}) ->
        {"mapping", Map.fetch!(mappings, {claim.source_id, key})}

      claim.route_distinguisher && Map.has_key?(by_rd, claim.route_distinguisher) ->
        {"route_distinguisher", Map.fetch!(by_rd, claim.route_distinguisher)}

      Map.has_key?(by_name, key) ->
        {"name", Map.fetch!(by_name, key)}

      key == "default" ->
        {"default", nil}

      true ->
        {"unmapped", nil}
    end
  end

  ## Reading

  @doc """
  The namespace an interface's addresses are in: `{:ok, vrf_id}`, with nil
  for the global table (also when the interface has no claim), or
  `:unmapped` when its claim resolves to nothing.
  """
  def namespace(organization_id, interface_id) do
    InterfaceRoutingDomain
    |> where([d], d.organization_id == ^organization_id and d.interface_id == ^interface_id)
    |> select([d], {d.resolution, d.vrf_id})
    |> Repo.one()
    |> case do
      nil -> {:ok, nil}
      {"unmapped", _vrf_id} -> :unmapped
      {_resolution, vrf_id} -> {:ok, vrf_id}
    end
  end

  @doc "The resolved routing domain of each of the interfaces, by interface id."
  def domains_for(%Scope{organization_id: organization_id}, interface_ids) do
    InterfaceRoutingDomain
    |> where([d], d.organization_id == ^organization_id and d.interface_id in ^interface_ids)
    |> preload(:vrf)
    |> Repo.all()
    |> Map.new(&{&1.interface_id, &1})
  end

  @doc """
  The routing domains sources currently report, one entry per source and
  key (ignoring case), with how the interfaces claiming it resolved and any
  explicit mapping. Mappings of keys nobody reports now are listed too, so
  they can still be reviewed and removed. Sorted by source name, then key.

  Each entry is `%{source:, key:, mapping:, outcomes:}`, where `outcomes` is
  `[%{resolution:, vrf:, interface_count:}]`: interfaces claiming one key
  can resolve differently when they report different route distinguishers.
  """
  def list_reported(%Scope{organization_id: organization_id} = scope) do
    outcomes =
      InterfaceRoutingDomain
      |> where([d], d.organization_id == ^organization_id)
      |> group_by([d], [
        d.source_id,
        fragment("lower(?)", d.source_local_key),
        d.resolution,
        d.vrf_id
      ])
      |> select([d], %{
        source_id: d.source_id,
        key: min(d.source_local_key),
        resolution: d.resolution,
        vrf_id: d.vrf_id,
        interface_count: count(d.interface_id)
      })
      |> Repo.all()

    mappings =
      Map.new(list_mappings(scope), &{{&1.source_id, String.downcase(&1.source_local_key)}, &1})

    sources = Map.new(Inventory.list_sources(scope), &{&1.id, &1})
    vrfs = Map.new(Repo.all(where(Vrf, [v], v.organization_id == ^organization_id)), &{&1.id, &1})

    reported =
      outcomes
      |> Enum.group_by(&{&1.source_id, String.downcase(&1.key)})
      |> Map.new(fn {{source_id, _} = id, rows} ->
        {id,
         %{
           source: Map.fetch!(sources, source_id),
           key: rows |> Enum.map(& &1.key) |> Enum.min(),
           mapping: Map.get(mappings, id),
           outcomes:
             rows
             |> Enum.map(
               &%{
                 resolution: &1.resolution,
                 vrf: &1.vrf_id && Map.get(vrfs, &1.vrf_id),
                 interface_count: &1.interface_count
               }
             )
             |> Enum.sort_by(&(-&1.interface_count))
         }}
      end)

    unreported =
      mappings
      |> Map.drop(Map.keys(reported))
      |> Map.new(fn {id, mapping} ->
        {id,
         %{source: mapping.source, key: mapping.source_local_key, mapping: mapping, outcomes: []}}
      end)

    reported
    |> Map.merge(unreported)
    |> Map.values()
    |> Enum.sort_by(&{String.downcase(&1.source.name), String.downcase(&1.key)})
  end

  @doc "Explicit mappings in the organization, with their source and VRF."
  def list_mappings(%Scope{organization_id: organization_id}) do
    RoutingDomainMapping
    |> where([m], m.organization_id == ^organization_id)
    |> order_by([m], asc: m.source_id, asc: fragment("lower(?)", m.source_local_key))
    |> preload([:source, :vrf])
    |> Repo.all()
  end

  ## Mapping and authority

  @doc """
  Maps one source's routing-domain key to a VRF, or to the global table
  with a nil `vrf_id`, replacing any mapping of the same key. Owners and
  admins only.
  """
  def put_mapping(%Scope{organization_id: organization_id} = scope, source_id, key, vrf_id) do
    Inventory.organization_management_transaction(scope, fn ->
      source = scoped_source!(organization_id, source_id)
      key = String.trim(key || "")

      existing =
        RoutingDomainMapping
        |> where([m], m.organization_id == ^organization_id and m.source_id == ^source.id)
        |> where([m], fragment("lower(?)", m.source_local_key) == ^String.downcase(key))
        |> lock("FOR UPDATE")
        |> Repo.one()

      (existing ||
         %RoutingDomainMapping{
           organization_id: organization_id,
           source_id: source.id,
           created_by_id: scope.user.id
         })
      |> RoutingDomainMapping.changeset(%{source_local_key: key, vrf_id: vrf_id})
      |> Repo.insert_or_update()
      |> case do
        {:ok, mapping} ->
          resolve_again(organization_id)
          mapping

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> Inventory.Changes.broadcast(organization_id)
  end

  @doc "Removes an explicit mapping; the key resolves automatically again."
  def delete_mapping(%Scope{organization_id: organization_id} = scope, mapping_id) do
    Inventory.organization_management_transaction(scope, fn ->
      mapping =
        RoutingDomainMapping
        |> where([m], m.organization_id == ^organization_id and m.id == ^mapping_id)
        |> Repo.one!()

      Repo.delete!(mapping)
      resolve_again(organization_id)
      mapping
    end)
    |> Inventory.Changes.broadcast(organization_id)
  end

  @doc "Sets whether a source's routing-domain claims are authoritative. Owners and admins only."
  def set_source_authority(%Scope{organization_id: organization_id} = scope, source_id, value)
      when is_boolean(value) do
    Inventory.organization_management_transaction(scope, fn ->
      source =
        organization_id
        |> scoped_source!(source_id)
        |> Source.routing_domain_authority_changeset(value)
        |> Repo.update!()

      resolve_again(organization_id)
      source
    end)
    |> Inventory.Changes.broadcast(organization_id)
  end

  @doc false
  # A changed mapping, authority, or VRF can move interfaces between
  # namespaces, so the address findings that compare in them follow.
  def resolve_again(organization_id) do
    {:ok, :ok} = refresh(organization_id)
    {:ok, :ok} = Renga.IPAM.AddressFindings.reconcile(organization_id)
    :ok
  end

  defp scoped_source!(organization_id, source_id) do
    Source
    |> where([s], s.organization_id == ^organization_id and s.id == ^source_id)
    |> Repo.one!()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
