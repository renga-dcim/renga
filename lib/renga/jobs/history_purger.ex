defmodule Renga.Jobs.HistoryPurger do
  @moduledoc """
  Periodically purges job history past each organization's retention with
  `Renga.Jobs.purge_history/0`.

  It runs apart from `Renga.Jobs.Sweeper` in the general background lane:
  lease and deadline sweeps have their own reserve and never wait behind
  retention. Each rotation performs one bounded batch per organization.
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
        Application.get_env(:renga, :job_purge_interval_ms, 5_000)
      )

    purge = Keyword.get(options, :purge, &purge/0)
    schedule(interval)
    {:ok, %{interval: interval, purge: purge}}
  end

  # History only needs to go eventually, so retention runs far less often
  # than the lease sweep.
  @impl true
  def handle_info(:purge, %{interval: interval, purge: purge} = state) do
    purge.()
    schedule(interval)
    {:noreply, state}
  end

  @doc false
  def purge do
    Jobs.purge_history()
  rescue
    error ->
      Logger.error("Job history purge failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("Job history purge failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(interval), do: Process.send_after(self(), :purge, interval)
end
