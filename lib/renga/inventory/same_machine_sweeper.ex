defmodule Renga.Inventory.SameMachineSweeper do
  @moduledoc """
  Periodically resolves "possible same machine" findings whose libvirt
  evidence has aged out by the server's clock (`Renga.Inventory.SameMachine.expire!/2`).
  Reports re-evaluate findings as they arrive; this covers a hypervisor that
  stops reporting at all.

  Follows the periodic-worker pattern of `Renga.Topology.NeighborExpiryWorker`.
  Each organization is swept under its lock, so every node may run this worker.
  """

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.SameMachine
  alias Renga.Repo

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
        Application.get_env(:renga, :same_machine_sweep_interval_ms, 60_000)
      )

    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval} = state) do
    sweep()
    schedule_sweep(interval)
    {:noreply, state}
  end

  @doc false
  def sweep(as_of \\ Renga.Time.utc_now_ms()) do
    CollectorFinding
    |> join(:inner, [finding], organization in Organization,
      on: organization.id == finding.organization_id
    )
    |> where(
      [finding, organization],
      organization.status == "active" and finding.kind == "possible_same_machine" and
        finding.status == "open"
    )
    |> distinct([finding, _organization], finding.organization_id)
    |> order_by([finding, _organization], asc: finding.organization_id)
    |> select([finding, _organization], finding.organization_id)
    |> Repo.all()
    |> Enum.map(&expire_tenant(%Scope{organization_id: &1}, as_of))
  end

  defp expire_tenant(scope, as_of) do
    SameMachine.expire!(scope, as_of)
  rescue
    error ->
      Logger.error(
        "Same-machine sweep failed for organization #{scope.organization_id}: #{Exception.message(error)}"
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.error(
        "Same-machine sweep failed for organization #{scope.organization_id}: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
