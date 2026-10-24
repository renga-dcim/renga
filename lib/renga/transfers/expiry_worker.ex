defmodule Renga.Transfers.ExpiryWorker do
  @moduledoc """
  Periodically expires organization exports after their seven days, deleting
  their archives, and fails exports a stopped node left running (RFD 20).
  """

  use GenServer
  require Logger

  alias Renga.Transfers

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
        Application.get_env(:renga, :transfer_expiry_interval_ms, 60_000)
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

  @doc false
  def sweep do
    Transfers.sweep()
  rescue
    error ->
      Logger.error("Export expiry sweep failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("Export expiry sweep failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
