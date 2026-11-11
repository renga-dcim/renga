defmodule Renga.Transfers.GenerationWorker do
  @moduledoc "Runs durably queued exports in a separate, bounded organization rotation."
  use GenServer
  require Logger

  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(options) do
    interval = Keyword.get(options, :interval, 1_000)
    sweep = Keyword.get(options, :sweep, &Renga.Transfers.generate_queued/0)
    Process.send_after(self(), :sweep, interval)
    {:ok, %{interval: interval, sweep: sweep}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval, sweep: sweep} = state) do
    try do
      sweep.()
    rescue
      error -> Logger.error("Export generation sweep failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :sweep, interval)
    {:noreply, state}
  end
end
