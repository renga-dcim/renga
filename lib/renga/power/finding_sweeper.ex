defmodule Renga.Power.FindingSweeper do
  @moduledoc """
  Periodically reconciles power findings (`Renga.Power.FindingReconciler`)
  for every organization with power inventory or readings.

  Measured findings depend on readings expiring by their event time, which
  no write announces, so they need a clock. Each organization reconciles
  under a transaction-scoped advisory lock that a busy organization skips,
  so every node may run this worker.
  """

  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Power.Feed
  alias Renga.Power.FindingReconciler
  alias Renga.Power.Port
  alias Renga.Power.Reading
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
        Application.get_env(:renga, :power_finding_interval_ms, 60_000)
      )

    sweep = Keyword.get(options, :sweep, &sweep/0)
    schedule(interval)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    sweep.()
    schedule(interval)
    {:noreply, state}
  end

  @doc "Reconciles every organization with power data; one failure does not stop the rest."
  def sweep do
    Enum.each(organizations(), fn organization ->
      reconcile(organization)
    end)
  end

  defp reconcile(organization) do
    organization |> Accounts.scope_for() |> FindingReconciler.reconcile()
  rescue
    error ->
      Logger.error(
        "Power finding reconciliation failed for organization #{organization.id}: " <>
          Exception.message(error)
      )

      {:error, error}
  end

  defp organizations do
    with_power =
      from(feed in Feed, select: feed.organization_id)
      |> union(^from(port in Port, select: port.organization_id))
      |> union(^from(reading in Reading, select: reading.organization_id))

    Organization
    |> where([organization], organization.status == "active")
    |> where([organization], organization.id in subquery(with_power))
    |> Repo.all()
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
