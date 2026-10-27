defmodule Renga.Operators.LifecycleWorker do
  @moduledoc "Retries due organization purges and durable owner notifications."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    # SMTP failure must not prevent enforcement of the purge deadline.
    for action <- [:deliver_notices, :sweep] do
      try do
        apply(Renga.Operators.OrganizationLifecycle, action, [])
      rescue
        error ->
          Logger.error("Organization lifecycle #{action} failed: #{Exception.message(error)}")
      end
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
