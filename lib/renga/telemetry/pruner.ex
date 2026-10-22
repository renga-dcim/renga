defmodule Renga.Telemetry.Pruner do
  @moduledoc """
  Periodically drops telemetry past its retention with
  `Renga.Telemetry.prune/0`: replay IDs no agent can still redeliver, and
  history past the store's enforced retention.

  The next prune is scheduled only after the last one finishes, so each
  node runs at most one at a time, and a prune that finds nothing to delete
  is cheap.
  """

  use GenServer
  require Logger

  alias Renga.Telemetry

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
        Application.get_env(:renga, :telemetry_prune_interval_ms, :timer.hours(1))
      )

    prune = Keyword.get(options, :prune, &prune/0)
    schedule(interval)
    {:ok, %{interval: interval, prune: prune}}
  end

  @impl true
  def handle_info(:prune, %{interval: interval, prune: prune} = state) do
    prune.()
    schedule(interval)
    {:noreply, state}
  end

  @doc false
  def prune do
    Telemetry.prune()
  rescue
    error ->
      Logger.error("Telemetry prune failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("Telemetry prune failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(interval), do: Process.send_after(self(), :prune, interval)
end
