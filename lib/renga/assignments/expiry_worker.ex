defmodule Renga.Assignments.ExpiryWorker do
  @moduledoc "Periodically records elapsed role-assignment deadlines in Activity."

  use GenServer
  require Logger

  alias Renga.Assignments

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
        Application.get_env(:renga, :assignment_expiry_interval_ms, 15_000)
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
    Assignments.sweep_expired()
  rescue
    error ->
      Logger.error("Assignment expiry sweep failed: #{Exception.message(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("Assignment expiry sweep failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
