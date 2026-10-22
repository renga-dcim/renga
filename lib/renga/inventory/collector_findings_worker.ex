defmodule Renga.Inventory.CollectorFindingsWorker do
  @moduledoc """
  Periodically refreshes the collector findings that time alone can change
  (`Renga.Inventory.CollectorFindings`), using the trusted server clock.
  """

  use GenServer
  require Logger

  alias Renga.Accounts.Scope
  alias Renga.Inventory.CollectorFindings

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
        Application.get_env(:renga, :collector_findings_interval_ms, 60_000)
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
  def sweep(now \\ Renga.Time.utc_now_ms()) do
    Enum.map(CollectorFindings.organization_ids(), fn organization_id ->
      refresh_tenant(%Scope{organization_id: organization_id}, now)
    end)
  end

  # One organization's failure never stops the others' sweep.
  defp refresh_tenant(scope, now) do
    CollectorFindings.refresh!(scope, now)
  rescue
    error ->
      Logger.error(
        "Collector findings sweep failed for organization #{scope.organization_id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
