defmodule Renga.Power.Endpoints do
  @moduledoc """
  Keeps a device's power ports and outlets in step with what its hardware
  type expects (RFD 10 phase 2), the way interface expectations come from
  interface templates.

  Endpoints are matched by name, so an operator's allocation override
  survives a template change. An endpoint the device no longer expects is
  removed, unless a power cable claim names it: cable claims are
  append-only history, so that endpoint is retired instead and comes back
  if the template defines it again.
  """

  import Ecto.Query, warn: false

  alias Renga.Catalog.ExpectedComponent
  alias Renga.Power.Outlet
  alias Renga.Power.Port
  alias Renga.Power.PowerFactor
  alias Renga.Repo
  alias Renga.Topology.CableAssertion

  @max_watts 999_999_999

  @doc """
  Brings `resource_id`'s endpoints in line with its unsuppressed
  `power_port` and `power_outlet` expectations. Runs inside the caller's
  transaction.
  """
  def sync!(organization_id, resource_id, hardware_assignment_id) do
    expected =
      ExpectedComponent
      |> where([component], component.organization_id == ^organization_id)
      |> where([component], component.hardware_assignment_id == ^hardware_assignment_id)
      |> where([component], component.kind in ["power_port", "power_outlet"])
      |> where([component], not component.suppressed)
      |> Repo.all()
      |> Enum.group_by(& &1.kind)

    now = Renga.Time.utc_now_ms()
    ports = Map.get(expected, "power_port", [])
    sync_ports!(organization_id, resource_id, ports, now)
    sync_outlets!(organization_id, resource_id, Map.get(expected, "power_outlet", []), now)
    :ok
  end

  defp sync_ports!(organization_id, resource_id, expected, now) do
    rows =
      Enum.map(expected, fn component ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          resource_id: resource_id,
          name: component.name,
          label: component.label,
          connector: text(component.attributes["connector"]),
          maximum_draw_w: watts(component.attributes["maximum_draw_w"]),
          default_allocated_draw_w: watts(component.attributes["allocated_draw_w"]),
          default_power_factor: PowerFactor.parse(component.attributes["power_factor"]),
          retired_at: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Port, rows,
      on_conflict:
        {:replace,
         [
           :label,
           :connector,
           :maximum_draw_w,
           :default_allocated_draw_w,
           :default_power_factor,
           :retired_at,
           :updated_at
         ]},
      conflict_target: [:organization_id, :resource_id, :name]
    )

    remove_unexpected!(Port, :power_port_id, organization_id, resource_id, names(expected), now)
  end

  defp sync_outlets!(organization_id, resource_id, expected, now) do
    inlets =
      Port
      |> where([port], port.organization_id == ^organization_id)
      |> where([port], port.resource_id == ^resource_id)
      |> select([port], {port.name, port.id})
      |> Repo.all()
      |> Map.new()

    rows =
      Enum.map(expected, fn component ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          resource_id: resource_id,
          inlet_port_id: Map.get(inlets, text(component.attributes["inlet"])),
          name: component.name,
          label: component.label,
          connector: text(component.attributes["connector"]),
          feed_leg: feed_leg(component.attributes["feed_leg"]),
          retired_at: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Outlet, rows,
      on_conflict:
        {:replace, [:inlet_port_id, :label, :connector, :feed_leg, :retired_at, :updated_at]},
      conflict_target: [:organization_id, :resource_id, :name]
    )

    remove_unexpected!(
      Outlet,
      :power_outlet_id,
      organization_id,
      resource_id,
      names(expected),
      now
    )
  end

  defp remove_unexpected!(schema, reference, organization_id, resource_id, names, now) do
    unexpected =
      from row in schema,
        as: :endpoint,
        where: row.organization_id == ^organization_id and row.resource_id == ^resource_id,
        where: row.name not in ^names

    # A current cable always has a claim behind it, and plans are intent that
    # goes with the endpoint, so claims alone decide what history to keep.
    claims =
      from claim in CableAssertion,
        where:
          claim.organization_id == parent_as(:endpoint).organization_id and
            field(claim, ^reference) == parent_as(:endpoint).id

    unexpected
    |> where([row], exists(claims) and is_nil(row.retired_at))
    |> Repo.update_all(set: [retired_at: now, updated_at: now])

    unexpected
    |> where(not exists(claims))
    |> Repo.delete_all()
  end

  defp names(expected), do: Enum.map(expected, & &1.name)

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  defp watts(value) when is_integer(value) and value > 0 and value <= @max_watts, do: value

  defp watts(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {watts, ""} -> watts(watts)
      _invalid -> nil
    end
  end

  defp watts(_value), do: nil

  defp feed_leg(value) when is_binary(value) do
    leg = value |> String.trim() |> String.downcase()
    if leg in ~w(a b c), do: leg
  end

  defp feed_leg(_value), do: nil
end
