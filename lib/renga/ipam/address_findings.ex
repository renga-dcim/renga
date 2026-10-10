defmodule Renga.IPAM.AddressFindings do
  @moduledoc """
  Reconciles the namespace-independent address findings (RFD 4, "Findings").

  Each run computes, for one organization, every condition that should be
  open now and makes the open findings match: new conditions open a finding,
  current ones are refreshed, and the rest resolve. Resolving never deletes
  anything, so observations, evidence, change events, and resolved findings
  keep the history. Runs serialize with inventory writes on the organization lock.

  Collectors do not report routing domains yet, so every observed address is
  in the global table (RFD 4, "Observation correlation") and is compared with
  global prefixes and global managed addresses only. Findings that need a
  namespace match, such as a stale assignment of a VRF address, wait for
  routing-domain claims.

  Only routable observed addresses count: loopback, link-local, and
  multicast addresses are unique by nobody's design. The kinds:

    * `unmanaged_in_strict_prefix` - inside a strict prefix (the most
      specific strict prefix containing it is named), observed without an
      active managed record.
    * `outside_prefix` - observed outside every global prefix, once the
      organization has a global prefix of that address family, so modeling
      only IPv4 never flags every IPv6 address.
    * `prefix_length_mismatch` - the observed mask disagrees with the most
      specific non-container prefix containing the host. A container is not a subnet, and
      a host-length report usually means the source did not know the mask,
      so neither is compared.
    * `duplicate_address` - one host observed on several interfaces, unless
      its managed address has a shared role (VIP, anycast, first-hop
      redundancy). One finding per interface, naming the others.
    * `stale_managed_assignment` - an allocated global address assigned to
      an interface that does not currently report it, on a resource some
      collector reports addresses for.
  """

  import Ecto.Query, warn: false

  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.IPAM.Cidr
  alias Renga.Repo

  # Unique by nobody's design: loopback, link-local, and multicast.
  @unroutable "'{127.0.0.0/8,169.254.0.0/16,224.0.0.0/4,::1/128,fe80::/10,ff00::/8}'::inet[]"

  @doc """
  Brings the organization's open address findings in line with current
  state. Safe to call inside a caller's transaction, which then also holds
  the lock until it commits.
  """
  def reconcile(organization_id) do
    Repo.transaction(fn ->
      # Match IPAM and collector lock order before reading or inserting findings.
      Renga.Inventory.lock_organization!(organization_id)

      now = Renga.Time.utc_now_ms()
      observed = observed_addresses(organization_id)
      families = prefix_families(organization_id)

      findings =
        Enum.flat_map(observed, &observed_findings(&1, families)) ++
          duplicate_findings(observed) ++ stale_findings(organization_id)

      findings
      |> with_evidence(organization_id)
      |> sync(organization_id, now)
    end)
  end

  ## Observed addresses

  defp observed_addresses(organization_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT address.id, address.interface_id, address.address,
               interface.name, device.id, COALESCE(device.display_name, device.name),
               COALESCE((address.metadata -> 'presence_owner' ->> 'observed_at')::timestamptz,
                        address.updated_at),
               nearest.id, nearest.prefix, nearest.status,
               subnet.id, subnet.prefix,
               strict_prefix.id, strict_prefix.prefix,
               managed.role
          FROM addresses AS address
          JOIN interfaces AS interface ON interface.id = address.interface_id
          JOIN resources AS device ON device.id = address.resource_id
          LEFT JOIN LATERAL (
            SELECT prefix.id, prefix.prefix, prefix.status
              FROM prefixes AS prefix
             WHERE prefix.organization_id = address.organization_id
               AND prefix.vrf_id IS NULL
               AND host(address.address)::inet <<= prefix.prefix
             ORDER BY masklen(prefix.prefix) DESC
             LIMIT 1
          ) AS nearest ON true
          LEFT JOIN LATERAL (
            SELECT prefix.id, prefix.prefix
              FROM prefixes AS prefix
             WHERE prefix.organization_id = address.organization_id
               AND prefix.vrf_id IS NULL
               AND prefix.status <> 'container'
               AND host(address.address)::inet <<= prefix.prefix
             ORDER BY masklen(prefix.prefix) DESC
             LIMIT 1
          ) AS subnet ON true
          LEFT JOIN LATERAL (
            SELECT prefix.id, prefix.prefix
              FROM prefixes AS prefix
             WHERE prefix.organization_id = address.organization_id
               AND prefix.vrf_id IS NULL
               AND prefix.strict
               AND host(address.address)::inet <<= prefix.prefix
             ORDER BY masklen(prefix.prefix) DESC
             LIMIT 1
          ) AS strict_prefix ON true
          LEFT JOIN LATERAL (
            SELECT ip.role
              FROM ip_addresses AS ip
              JOIN resources AS envelope ON envelope.id = ip.resource_id
             WHERE ip.organization_id = address.organization_id
               AND ip.vrf_id IS NULL
               AND host(ip.address)::inet = host(address.address)::inet
               AND envelope.lifecycle_state <> 'retired'
             LIMIT 1
          ) AS managed ON true
         WHERE address.organization_id = $1
           AND (address.metadata -> 'present') IS DISTINCT FROM 'false'::jsonb
           AND NOT host(address.address)::inet <<= ANY(#{@unroutable})
        """,
        [Ecto.UUID.dump!(organization_id)]
      )

    Enum.map(rows, fn [
                        id,
                        interface_id,
                        address,
                        interface,
                        device_id,
                        device,
                        observed_at | rest
                      ] ->
      [nearest_id, nearest, nearest_status, subnet_id, subnet, strict_id, strict, managed_role] =
        rest

      %{
        id: Ecto.UUID.load!(id),
        interface_id: Ecto.UUID.load!(interface_id),
        address: address,
        host: host(address),
        interface: interface,
        resource_id: Ecto.UUID.load!(device_id),
        resource: device,
        observed_at: observed_at,
        nearest:
          nearest_id && %{id: Ecto.UUID.load!(nearest_id), cidr: nearest, status: nearest_status},
        subnet: subnet_id && %{id: Ecto.UUID.load!(subnet_id), cidr: subnet},
        strict: strict_id && %{id: Ecto.UUID.load!(strict_id), cidr: strict},
        managed_role: managed_role
      }
    end)
  end

  defp prefix_families(organization_id) do
    from(prefix in Renga.Inventory.Prefix,
      where: prefix.organization_id == ^organization_id and is_nil(prefix.vrf_id),
      select: prefix.prefix
    )
    |> Repo.all()
    |> MapSet.new(&Cidr.family/1)
  end

  defp observed_findings(observed, families) do
    [
      unmanaged_in_strict(observed),
      outside_prefix(observed, families),
      prefix_length_mismatch(observed)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp unmanaged_in_strict(%{strict: %{} = strict, managed_role: nil} = observed) do
    observed_finding(
      observed,
      "unmanaged_in_strict_prefix",
      "#{observed.host} is observed in strict prefix #{Cidr.format(strict.cidr)} without a managed record",
      %{"prefix_id" => strict.id, "prefix" => Cidr.format(strict.cidr)}
    )
  end

  defp unmanaged_in_strict(_observed), do: nil

  defp outside_prefix(%{nearest: nil, address: address} = observed, families) do
    if MapSet.member?(families, Cidr.family(address)) do
      observed_finding(
        observed,
        "outside_prefix",
        "#{observed.host} is observed outside every prefix",
        %{}
      )
    end
  end

  defp outside_prefix(_observed, _families), do: nil

  defp prefix_length_mismatch(%{subnet: %{} = nearest, address: address} = observed) do
    length = Cidr.length(address)
    expected = Cidr.length(nearest.cidr)
    host_length = address |> Cidr.family() |> Cidr.bits()

    if length != host_length and length != expected do
      observed_finding(
        observed,
        "prefix_length_mismatch",
        "#{observed.host} is observed as /#{length} in prefix #{Cidr.format(nearest.cidr)}",
        %{
          "prefix_id" => nearest.id,
          "prefix" => Cidr.format(nearest.cidr),
          "observed_length" => length,
          "prefix_length" => expected
        }
      )
    end
  end

  defp prefix_length_mismatch(_observed), do: nil

  # Shared roles exist to be on several interfaces at once; anything else
  # on more than one is a conflict, whatever masks each reports.
  defp duplicate_findings(observed) do
    observed
    |> Enum.reject(&IPAM.shared_role?(&1.managed_role))
    |> Enum.group_by(& &1.host)
    |> Enum.flat_map(fn {_host, copies} ->
      interfaces = Enum.uniq_by(copies, & &1.interface_id)

      if length(interfaces) > 1 do
        Enum.map(interfaces, &duplicate_finding(&1, interfaces))
      else
        []
      end
    end)
  end

  defp duplicate_finding(observed, interfaces) do
    others =
      interfaces
      |> Enum.reject(&(&1.interface_id == observed.interface_id))
      |> Enum.sort_by(&{&1.resource, &1.interface})

    [first | _rest] = others

    message =
      case length(others) do
        1 -> "#{observed.host} is also observed on #{first.interface} on #{first.resource}"
        count -> "#{observed.host} is also observed on #{count} other interfaces"
      end

    observed_finding(observed, "duplicate_address", message, %{
      "others" =>
        Enum.map(others, fn other ->
          %{
            "interface_id" => other.interface_id,
            "interface" => other.interface,
            "resource_id" => other.resource_id,
            "resource" => other.resource
          }
        end)
    })
  end

  defp observed_finding(observed, kind, message, details) do
    %{
      interface_id: observed.interface_id,
      kind: kind,
      resolution_key: observed.host,
      message: message,
      details:
        Map.merge(details, %{
          "address" => Cidr.format(observed.address),
          "observed_address_id" => observed.id
        }),
      observed_address_id: observed.id,
      last_observed_at: observed.observed_at
    }
  end

  ## Stale assignments

  # Only resources a collector reports addresses for: on a resource nobody
  # observes, every documented assignment would be "not observed".
  defp stale_findings(organization_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT assignment.interface_id, ip.id, ip.address, interface.name
          FROM ip_address_assignments AS assignment
          JOIN ip_addresses AS ip ON ip.id = assignment.ip_address_id
          JOIN resources AS envelope ON envelope.id = ip.resource_id
          JOIN interfaces AS interface ON interface.id = assignment.interface_id
         WHERE assignment.organization_id = $1
           AND ip.vrf_id IS NULL
           AND ip.allocation_state = 'allocated'
           AND envelope.lifecycle_state <> 'retired'
           AND NOT EXISTS (
             SELECT 1 FROM addresses AS address
              WHERE address.organization_id = assignment.organization_id
                AND address.interface_id = assignment.interface_id
                AND host(address.address)::inet = host(ip.address)::inet
                AND (address.metadata -> 'present') IS DISTINCT FROM 'false'::jsonb
           )
           AND EXISTS (
             SELECT 1 FROM addresses AS reported
              JOIN address_evidence AS evidence ON evidence.address_id = reported.id
              WHERE reported.organization_id = assignment.organization_id
                AND reported.resource_id = interface.resource_id
           )
        """,
        [Ecto.UUID.dump!(organization_id)]
      )

    Enum.map(rows, fn [interface_id, ip_id, address, interface] ->
      ip_id = Ecto.UUID.load!(ip_id)

      %{
        interface_id: Ecto.UUID.load!(interface_id),
        kind: "stale_managed_assignment",
        resolution_key: ip_id,
        message: "Managed address #{host(address)} is not observed on #{interface}",
        details: %{"ip_address_id" => ip_id, "address" => Cidr.format(address)},
        observed_address_id: nil,
        last_observed_at: nil
      }
    end)
  end

  ## Evidence

  # Source evidence for findings about an observed address: each source's
  # most recent report of each mask, newest first.
  defp with_evidence(findings, organization_id) do
    ids = findings |> Enum.map(& &1.observed_address_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    evidence = evidence_by_address(organization_id, ids)

    Enum.map(findings, fn finding ->
      case Map.get(evidence, finding.observed_address_id) do
        nil -> finding
        reports -> put_in(finding, [:details, "evidence"], reports)
      end
    end)
  end

  defp evidence_by_address(_organization_id, []), do: %{}

  defp evidence_by_address(organization_id, ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT ON (evidence.address_id, evidence.source_id, evidence.address)
               evidence.address_id, evidence.source_id, source.kind, source.name,
               evidence.observation_id, evidence.observed_at, evidence.address
          FROM address_evidence AS evidence
          JOIN sources AS source ON source.id = evidence.source_id
         WHERE evidence.organization_id = $1 AND evidence.address_id = ANY($2)
         ORDER BY evidence.address_id, evidence.source_id, evidence.address,
                  evidence.observed_at DESC
        """,
        [Ecto.UUID.dump!(organization_id), Enum.map(ids, &Ecto.UUID.dump!/1)]
      )

    rows
    |> Enum.map(fn [address_id, source_id, kind, name, observation_id, observed_at, address] ->
      {Ecto.UUID.load!(address_id),
       %{
         "source_id" => Ecto.UUID.load!(source_id),
         "source_kind" => kind,
         "source" => name,
         "observation_id" => Ecto.UUID.load!(observation_id),
         "observed_at" => observed_at |> to_utc() |> DateTime.to_iso8601(),
         "address" => Cidr.format(address)
       }}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, reports} -> {id, Enum.sort_by(reports, & &1["observed_at"], :desc)} end)
  end

  ## Opening, refreshing, and resolving

  defp sync(findings, organization_id, now) do
    open =
      AddressFinding
      |> where([finding], finding.organization_id == ^organization_id)
      |> where([finding], finding.status == "open")
      |> Repo.all()
      |> Map.new(&{{&1.interface_id, &1.kind, &1.resolution_key}, &1})

    desired = Map.new(findings, &{{&1.interface_id, &1.kind, &1.resolution_key}, &1})

    Enum.each(desired, fn {key, finding} ->
      put_finding(organization_id, Map.get(open, key), finding, now)
    end)

    open
    |> Map.drop(Map.keys(desired))
    |> Map.values()
    |> Enum.each(&resolve(&1, now))

    :ok
  end

  defp put_finding(organization_id, nil, finding, now) do
    %AddressFinding{organization_id: organization_id, interface_id: finding.interface_id}
    |> AddressFinding.changeset(attrs(finding, now))
    |> Repo.insert!()
  end

  # An unchanged condition is not rewritten, so a reconcile that finds
  # nothing new writes nothing.
  defp put_finding(_organization_id, existing, finding, _now) do
    attrs = attrs(finding, existing.last_observed_at)

    attrs =
      Map.update!(attrs, :last_observed_at, &latest(&1, existing.last_observed_at))

    changeset = AddressFinding.changeset(existing, attrs)
    if changeset.changes != %{}, do: Repo.update!(changeset)
  end

  defp attrs(finding, default_observed_at) do
    %{
      kind: finding.kind,
      resolution_key: finding.resolution_key,
      message: finding.message,
      details: finding.details,
      status: "open",
      resolved_at: nil,
      last_observed_at: to_utc(finding.last_observed_at || default_observed_at)
    }
  end

  defp resolve(finding, now) do
    finding
    |> AddressFinding.changeset(%{
      status: "resolved",
      resolved_at: latest(now, finding.last_observed_at)
    })
    |> Repo.update!()
  end

  defp latest(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  defp host(%Postgrex.INET{} = inet),
    do: Cidr.format(%{inet | netmask: inet |> Cidr.family() |> Cidr.bits()})

  defp to_utc(%DateTime{} = datetime), do: DateTime.truncate(datetime, :millisecond)

  defp to_utc(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:millisecond)
end
