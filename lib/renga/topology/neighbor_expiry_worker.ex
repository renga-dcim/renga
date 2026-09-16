defmodule Renga.Topology.NeighborExpiryWorker do
  @moduledoc "Periodically expires LLDP/CDP evidence using the trusted server clock."

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.InterfaceNeighborEvidence

  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    server_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, server_options)
  end

  @impl true
  def init(options) do
    interval =
      Keyword.get(
        options,
        :interval,
        Application.get_env(:renga, :neighbor_expiry_interval_ms, 30_000)
      )

    sweep = Keyword.get(options, :sweep, &sweep/0)
    schedule_sweep(interval)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    sweep.()
    schedule_sweep(interval)
    {:noreply, state}
  end

  @doc false
  def sweep(as_of \\ Renga.Time.utc_now_ms(), expire \\ &Topology.expire_interface_neighbors/2) do
    InterfaceNeighborEvidence
    |> join(:inner, [evidence], organization in Organization,
      on: organization.id == evidence.organization_id
    )
    |> where(
      [evidence, organization],
      organization.status == "active" and is_nil(evidence.stale_at) and
        evidence.expires_at <= ^as_of
    )
    |> distinct([evidence, _organization], evidence.organization_id)
    |> order_by([evidence, _organization], asc: evidence.organization_id)
    |> select([evidence, _organization], evidence.organization_id)
    |> Repo.all()
    |> Enum.map(fn organization_id ->
      scope = %Scope{organization_id: organization_id, roles: ["topology_reconciler"]}
      expire_tenant(expire, scope, as_of)
    end)
  end

  defp expire_tenant(expire, scope, as_of) do
    expire.(scope, as_of)
  rescue
    error ->
      Logger.error(
        "Neighbor expiry sweep failed for organization #{scope.organization_id}: #{Exception.message(error)}"
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.error(
        "Neighbor expiry sweep failed for organization #{scope.organization_id}: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
