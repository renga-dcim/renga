defmodule Renga.Operators.InvitationDeliveryWorker do
  @moduledoc """
  Recovers queued operator invitation emails after failures and restarts.

  Delivery rows are durable and leased with `SKIP LOCKED`, so every node may
  run this worker. The first sweep runs at startup to close the commit-to-send
  crash window quickly.
  """

  use GenServer
  require Logger

  alias Renga.Operators.InvitationDeliveries

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
        Application.get_env(:renga, :invitation_delivery_interval_ms, 15_000)
      )

    sweep = Keyword.get(options, :sweep, &InvitationDeliveries.sweep/0)
    send(self(), :sweep)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    run_sweep(sweep)
    Process.send_after(self(), :sweep, interval)
    {:noreply, state}
  end

  defp run_sweep(sweep) do
    sweep.()
  rescue
    error ->
      Logger.error("Operator invitation delivery sweep failed: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.error("Operator invitation delivery sweep failed: #{inspect({kind, reason})}")
  end
end
