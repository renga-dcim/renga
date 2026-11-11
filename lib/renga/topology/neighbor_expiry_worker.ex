defmodule Renga.Topology.NeighborExpiryWorker do
  @moduledoc "Periodically expires LLDP/CDP evidence using the trusted server clock."

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Topology.NeighborGeneration
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
        Application.get_env(:renga, :neighbor_expiry_interval_ms, 1_000)
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
  def sweep(as_of \\ Renga.Time.utc_now_ms(), expire \\ &advance_turn/2) do
    from(organization in Organization, as: :organization)
    |> where([organization], organization.status == "active")
    |> where(
      [organization],
      exists(
        from e in InterfaceNeighborEvidence,
          where:
            e.organization_id == parent_as(:organization).id and is_nil(e.stale_at) and
              e.expires_at <= ^as_of,
          select: 1
      ) or
        fragment(
          "EXISTS (SELECT 1 FROM neighbor_generations g WHERE g.organization_id = ? AND g.status IN ('building','published','obsolete'))",
          organization.id
        )
    )
    |> select([organization], %{organization_id: organization.id})
    |> then(
      &Renga.Background.run("neighbor_expiry", &1, fn organization_id ->
        scope = %Scope{organization_id: organization_id, roles: ["topology_reconciler"]}
        expire_tenant(expire, scope, as_of)
      end)
    )
    |> Enum.map(fn
      {:ok, result} -> result
      failed -> failed
    end)
  end

  # Commit each small unit before attempting the next one. The scheduler's
  # outer deadline may cancel the last unit without discarding earlier work.
  defp advance_turn(scope, as_of) do
    deadline = System.monotonic_time(:millisecond) + 150

    Enum.reduce_while(1..100, nil, fn _, _ ->
      result = NeighborGeneration.step(scope, as_of)

      if result in [{:ok, :building}, {:ok, :compacting}] and
           System.monotonic_time(:millisecond) < deadline,
         do: {:cont, result},
         else: {:halt, result}
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
