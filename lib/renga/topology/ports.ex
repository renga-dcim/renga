defmodule Renga.Topology.Ports do
  @moduledoc """
  One device's physical ports with everything the Ports tab shows (RFD 8,
  "Switch ports"): link status and speed, the LLDP neighbor and the cable
  (as `Renga.Topology.Links`, so they carry the same agreement states as the
  topology map), and the VLAN mode and membership that is desired and that
  collectors observe.

  A port has VLAN drift when reconciliation holds an open VLAN finding for
  it, and the VLANs marked missing or unexpected are the ones those
  findings name. Findings stay the authority on drift because they know
  when a snapshot is partial or evidence is ambiguous.

  Building ports is pure: `Renga.Topology.list_resource_ports/2` loads the
  records in batches for the whole device.
  """

  defstruct [
    :interface,
    :neighbor,
    :cable,
    :plan,
    :desired,
    :observed,
    unresolved: [],
    findings: [],
    missing: [],
    unexpected: []
  ]

  @typedoc """
  VLAN membership on one side (desired or observed): the mode and the
  untagged and tagged VLANs. `nil` when that side says nothing at all.
  """
  @type membership :: %{mode: String.t() | nil, untagged: struct() | nil, tagged: [struct()]}

  @doc "Interface kinds that are physical ports."
  def port_kinds, do: ~w(ethernet)

  @doc """
  Builds ports for `interfaces` from the device's links and VLAN records.

  `records` holds lists under `:links`, `:unresolved` (neighbor evidence),
  `:desired` and `:observed` (VLAN assignments and memberships), `:desired_modes`
  and `:observed_modes`, and `:findings` (open VLAN findings).
  """
  def build(interfaces, records) do
    links = Map.get(records, :links, [])
    by_interface = fn key -> Enum.group_by(Map.get(records, key, []), &interface_id/1) end

    unresolved = by_interface.(:unresolved)
    desired = by_interface.(:desired)
    observed = by_interface.(:observed)
    desired_modes = Map.new(Map.get(records, :desired_modes, []), &{&1.interface_id, &1.mode})
    observed_modes = Map.new(Map.get(records, :observed_modes, []), &{&1.interface_id, &1.mode})
    findings = by_interface.(:findings)

    interfaces
    |> Enum.filter(&(&1.kind in port_kinds()))
    |> Enum.sort_by(&natural_key(&1.name))
    |> Enum.map(fn interface ->
      id = interface.id
      touching = Enum.filter(links, &(id in [&1.interface_a.id, &1.interface_b.id]))
      desired = membership(Map.get(desired_modes, id), Map.get(desired, id, []))
      observed = membership(Map.get(observed_modes, id), Map.get(observed, id, []))

      %__MODULE__{
        interface: interface,
        neighbor: Enum.find(touching, & &1.adjacency),
        cable: Enum.find(touching, & &1.cable),
        plan: Enum.find(touching, & &1.plan),
        unresolved: Map.get(unresolved, id, []),
        desired: desired,
        observed: observed,
        findings: Map.get(findings, id, [])
      }
      |> compare(desired, observed)
    end)
  end

  @doc "Whether a port has VLAN drift."
  def drift?(%__MODULE__{findings: findings}), do: findings != []

  @doc "The far end of a link from this port."
  def far_end(%__MODULE__{interface: %{id: id}}, %{interface_a: %{id: id}, interface_b: far}),
    do: far

  def far_end(%__MODULE__{}, %{interface_a: far}), do: far

  @doc """
  A sort key that orders port names as people count them: `swp2` before
  `swp10`, and `Ethernet1/2` before `Ethernet1/10`.
  """
  def natural_key(name) do
    ~r/\d+/
    |> Regex.split(name, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {number, ""} -> {0, number}
        _text -> {1, String.downcase(part)}
      end
    end)
  end

  defp membership(nil, []), do: nil

  defp membership(mode, records) do
    {untagged, tagged} = Enum.split_with(records, &(&1.tagging_mode == "untagged"))

    %{
      mode: mode,
      untagged: untagged |> Enum.map(& &1.vlan) |> List.first(),
      tagged: tagged |> Enum.map(& &1.vlan) |> Enum.sort_by(& &1.vid)
    }
  end

  # Which VLANs differ, as reconciliation sees them: a desired VLAN with a
  # missing_vlan finding, and an observed VLAN with an unexpected_vlan
  # finding. Comparing the sets directly would also flag VLANs that a
  # partial snapshot simply did not report.
  defp compare(port, desired, observed) do
    flagged = fn kind ->
      port.findings
      |> Enum.filter(&(&1.kind == kind))
      |> MapSet.new(&get_in(&1.details, ["vlan_id"]))
    end

    %{
      port
      | missing: flagged_vlans(desired, flagged.("missing_vlan")),
        unexpected: flagged_vlans(observed, flagged.("unexpected_vlan"))
    }
  end

  defp flagged_vlans(nil, _ids), do: []

  defp flagged_vlans(%{untagged: untagged, tagged: tagged}, ids) do
    untagged
    |> List.wrap()
    |> Enum.map(&%{tagging: :untagged, vlan: &1})
    |> Enum.concat(Enum.map(tagged, &%{tagging: :tagged, vlan: &1}))
    |> Enum.filter(&MapSet.member?(ids, &1.vlan.id))
  end

  defp interface_id(%{local_interface_id: id}), do: id
  defp interface_id(%{interface_id: id}), do: id
end
