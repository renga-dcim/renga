defmodule Renga.Jobs.Sweeper do
  @moduledoc """
  Periodically sweeps lapsed job leases and expired deadlines (RFD 9), so
  abandoned work never stays `leased` or `running` forever. Retention runs
  separately in `Renga.Jobs.HistoryPurger`, so a long purge never delays it.

  Follows the periodic-worker pattern of `Renga.Topology.NeighborExpiryWorker`.
  `Renga.Jobs.sweep/1` is idempotent and locks with `SKIP LOCKED`, so every
  node may run this worker.
  """

  use GenServer
  require Logger

  alias Renga.Jobs

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
        Application.get_env(:renga, :job_sweep_interval_ms, 15_000)
      )

    sweep = Keyword.get(options, :sweep, &sweep/0)
    schedule(:sweep, interval)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    sweep.()
    schedule(:sweep, interval)
    {:noreply, state}
  end

  @doc false
  def sweep, do: logging_failure("Job sweep", &Jobs.sweep/0)

  defp logging_failure(label, fun) do
    fun.()
  rescue
    error ->
      Logger.error("#{label} failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("#{label} failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(message, interval), do: Process.send_after(self(), message, interval)
end
