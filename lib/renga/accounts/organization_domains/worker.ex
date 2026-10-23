defmodule Renga.Accounts.OrganizationDomains.Worker do
  @moduledoc """
  Checks every verified organization domain's DNS record again once a day,
  so a domain whose record was removed stops routing sign-in (RFD 15). The
  first check runs as soon as the worker starts: a timer that restarts with
  every deploy would otherwise never fire on a deployment that restarts
  more often than daily.
  Follows the periodic-worker pattern of `Renga.Assignments.ExpiryWorker`.
  """

  use GenServer
  require Logger

  alias Renga.Accounts.OrganizationDomains

  @day_ms 24 * 60 * 60 * 1000

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
        Application.get_env(:renga, :organization_domain_check_interval_ms, @day_ms)
      )

    sweep = Keyword.get(options, :sweep, &sweep/0)
    send(self(), :sweep)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    sweep.()
    schedule(interval)
    {:noreply, state}
  end

  @doc false
  def sweep do
    OrganizationDomains.recheck_verified()
  rescue
    error ->
      Logger.error("Organization domain check failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("Organization domain check failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
