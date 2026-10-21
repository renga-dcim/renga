defmodule Renga.Power.Cables do
  @moduledoc """
  Power connections (RFD 10 phase 2): RFD 7's plan, assertion, and current
  cable model with the `power` cable kind.

  A power cable joins a power port (side a) to an outlet or a feed (side b).
  Assertions are confirmed, attributed, and append-only like data cable
  claims, and the same reconciliation selects the newest claim for each
  endpoint as its current cable. A plan is intent and never occupies an
  endpoint.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Power.Feed
  alias Renga.Power.Outlet
  alias Renga.Power.Port
  alias Renga.Repo
  alias Renga.Topology.Cable
  alias Renga.Topology.CableAssertion
  alias Renga.Topology.CablePlan
  alias Renga.Topology.CableReconciler

  @endpoint_keys ~w(power_port_id power_outlet_id power_feed_id)a
  @attribute_keys ~w(cable_type status label color length_value length_unit description metadata)a

  @doc """
  Current power cables touching any of `resource_ids`' ports or outlets, or
  every one in the organization without the option, with their endpoints.
  """
  def list_cables(%Scope{organization_id: organization_id}, opts \\ []) do
    Cable
    |> where([cable], cable.organization_id == ^organization_id and cable.cable_kind == "power")
    |> maybe_touching(Keyword.get(opts, :resource_ids))
    |> preload(^endpoint_preloads())
    |> Repo.all()
  end

  @doc "Power cable plans, with their endpoints."
  def list_plans(%Scope{organization_id: organization_id}, opts \\ []) do
    CablePlan
    |> where([plan], plan.organization_id == ^organization_id and plan.cable_kind == "power")
    |> maybe_touching(Keyword.get(opts, :resource_ids))
    |> preload(^endpoint_preloads())
    |> Repo.all()
  end

  @doc """
  What a port on `resource_id` can be plugged into: the organization's
  outlets on other devices, by device, and its feeds, by panel. Retired
  outlets are left out.
  """
  def connectable(%Scope{organization_id: organization_id}, resource_id) do
    outlets =
      Outlet
      |> join(:inner, [outlet], resource in assoc(outlet, :resource))
      |> where([outlet], outlet.organization_id == ^organization_id)
      |> where([outlet], outlet.resource_id != ^resource_id and is_nil(outlet.retired_at))
      |> order_by([outlet, resource],
        asc: resource.name,
        asc: fragment(~s(? COLLATE "C"), outlet.name)
      )
      |> preload([_outlet, resource], resource: resource)
      |> Repo.all()

    feeds =
      Feed
      |> join(:inner, [feed], panel in assoc(feed, :panel))
      |> where([feed], feed.organization_id == ^organization_id)
      |> order_by([feed, panel], asc: panel.name, asc: feed.name)
      |> preload([_feed, panel], panel: panel)
      |> Repo.all()

    %{outlets: outlets, feeds: feeds}
  end

  @doc """
  Records that a port is plugged into an outlet or feed, as the scope's
  user. The port's and the outlet's earlier cables are replaced.
  """
  def connect(%Scope{} = scope, attrs), do: put_assertion(scope, attrs, "assert")

  @doc "Records that the port is no longer plugged into that outlet or feed."
  def disconnect(%Scope{} = scope, attrs), do: put_assertion(scope, attrs, "retract")

  @doc "Records or updates the intended connection for a port and an outlet or feed."
  def put_plan(%Scope{} = scope, attrs) do
    transaction(scope, fn ->
      endpoints = endpoints!(scope, attrs, live?: true)

      plan =
        CablePlan
        |> Repo.get_by([organization_id: scope.organization_id] ++ Map.to_list(endpoints))
        |> case do
          nil -> struct(%CablePlan{organization_id: scope.organization_id}, endpoints)
          plan -> plan
        end
        |> CablePlan.power_changeset(Map.take(attrs, @attribute_keys))
        |> Repo.insert_or_update()

      with {:ok, _plan} <- plan, do: CableReconciler.reconcile(scope)
      plan
    end)
  end

  @doc "Removes a power cable plan."
  def delete_plan(%Scope{} = scope, %CablePlan{cable_kind: "power", id: id}) do
    transaction(scope, fn ->
      CablePlan
      |> where([plan], plan.organization_id == ^scope.organization_id and plan.id == ^id)
      |> Repo.one!()
      |> Repo.delete()
    end)
  end

  defp put_assertion(scope, attrs, action) do
    transaction(scope, fn ->
      endpoints = endpoints!(scope, attrs, live?: action == "assert")
      details = if action == "assert", do: Map.take(attrs, @attribute_keys), else: %{}

      assertion =
        %CableAssertion{organization_id: scope.organization_id, actor_user_id: actor(scope)}
        |> struct(endpoints)
        |> CableAssertion.power_changeset(
          Map.merge(details, %{
            kind: "operator",
            action: action,
            confirmation: "confirmed",
            asserted_at: Renga.Time.utc_now_ms()
          })
        )
        |> Repo.insert()

      with {:ok, _assertion} <- assertion, do: CableReconciler.reconcile(scope)
      assertion
    end)
  end

  # The port and exactly one of an outlet or a feed, all in the scope's
  # organization. A new connection needs endpoints the devices still have,
  # and never loops a device's outlet back into its own port.
  defp endpoints!(scope, attrs, live?: live?) do
    endpoints =
      @endpoint_keys
      |> Map.new(&{&1, attrs[&1] || attrs[Atom.to_string(&1)]})
      |> Map.reject(fn {_key, id} -> id in [nil, ""] end)

    port = fetch(Port, scope, endpoints[:power_port_id])

    case check_endpoints(port, far_endpoint(scope, endpoints), live?) do
      :ok -> endpoints
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Exactly one of an outlet or a feed; both, or neither, is no endpoint.
  defp far_endpoint(scope, endpoints) do
    case {endpoints[:power_outlet_id], endpoints[:power_feed_id]} do
      {outlet_id, nil} -> fetch(Outlet, scope, outlet_id)
      {nil, feed_id} -> fetch(Feed, scope, feed_id)
      {_outlet_id, _feed_id} -> nil
    end
  end

  defp check_endpoints(port, far, _live?) when is_nil(port) or is_nil(far),
    do: {:error, :power_cable_endpoints}

  defp check_endpoints(port, far, live?) do
    cond do
      live? and (retired?(port) or retired?(far)) -> {:error, :power_endpoint_retired}
      loop?(port, far) -> {:error, :power_loop}
      true -> :ok
    end
  end

  defp loop?(port, %Outlet{resource_id: resource_id}), do: resource_id == port.resource_id
  defp loop?(_port, _feed), do: false

  defp fetch(_schema, _scope, nil), do: nil

  defp fetch(schema, scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(schema, organization_id: scope.organization_id, id: id)
      :error -> nil
    end
  end

  defp retired?(%{retired_at: retired_at}), do: not is_nil(retired_at)
  defp retired?(_feed), do: false

  defp maybe_touching(query, nil), do: query

  defp maybe_touching(query, resource_ids) do
    ports = from(port in Port, where: port.resource_id in ^resource_ids, select: port.id)

    outlets =
      from(outlet in Outlet, where: outlet.resource_id in ^resource_ids, select: outlet.id)

    where(
      query,
      [row],
      row.power_port_id in subquery(ports) or row.power_outlet_id in subquery(outlets)
    )
  end

  defp endpoint_preloads,
    do: [power_port: :resource, power_outlet: [:resource, :inlet_port], power_feed: :panel]

  defp transaction(scope, mutation) do
    scope
    |> Inventory.organization_management_transaction(fn ->
      CableReconciler.lock_state!(scope.organization_id)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  defp actor(%Scope{user: %{id: id}}), do: id
  defp actor(%Scope{}), do: nil
end
