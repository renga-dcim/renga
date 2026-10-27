defmodule Renga.IntakeContactWorker do
  @moduledoc "Flushes a bounded, coalesced authenticated-contact batch off the request path."
  use GenServer
  require Logger

  def start_link(options) do
    if Application.get_env(:renga, :intake_contact_worker_enabled, true),
      do: GenServer.start_link(__MODULE__, options, name: __MODULE__),
      else: :ignore
  end

  @impl true
  def init(_options) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule()
    {:noreply, state}
  end

  defp flush do
    Renga.IntakeCapacity.flush_contacts()
  rescue
    error -> Logger.warning("Intake contact flush failed: #{Exception.message(error)}")
  end

  defp schedule, do: Process.send_after(self(), :flush, 1_000)
end
