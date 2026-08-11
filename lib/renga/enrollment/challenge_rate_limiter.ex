defmodule Renga.Enrollment.ChallengeRateLimiter do
  @moduledoc """
  Bounded, node-local admission guard for public challenge issuance.

  The database's per-profile open-challenge cap remains authoritative across
  nodes. This process only absorbs bursts reaching one application node.
  """

  use GenServer

  @type source :: :inet.ip_address()

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc "Consumes one allowance for a source and organization/profile tuple."
  @spec allow?(source(), binary(), binary()) :: boolean()
  def allow?(source, organization, profile) do
    digest = :crypto.hash(:sha256, organization <> <<0>> <> profile)
    GenServer.call(__MODULE__, {:allow, source, digest})
  end

  @doc false
  def reset_for_test(now \\ 0), do: GenServer.call(__MODULE__, {:reset_for_test, now})

  @doc false
  def advance_for_test(milliseconds),
    do: GenServer.call(__MODULE__, {:advance_for_test, milliseconds})

  @impl true
  def init(_options) do
    config = Application.fetch_env!(:renga, __MODULE__)

    with {:ok, state} <- configured_state(config) do
      schedule_prune(state.prune_interval)
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:allow, source, digest}, _from, state) do
    now = now(state)
    state = prune_expired(state, now)

    keys = [
      {{:source, source}, state.source_limit},
      {{:tuple, source, digest}, state.tuple_limit}
    ]

    missing_keys = Enum.count(keys, fn {key, _limit} -> not Map.has_key?(state.entries, key) end)

    if map_size(state.entries) + missing_keys <= state.max_keys and
         Enum.all?(keys, fn {key, limit} -> available?(state, key, limit, now) end) do
      entries =
        Enum.reduce(keys, state.entries, fn {key, _}, entries ->
          increment(entries, key, now, state.window)
        end)

      {:reply, true, %{state | entries: entries}}
    else
      {:reply, false, state}
    end
  end

  def handle_call({:reset_for_test, now}, _from, state),
    do: {:reply, :ok, %{state | entries: %{}, test_now: now}}

  def handle_call({:advance_for_test, milliseconds}, _from, %{test_now: now} = state)
      when is_integer(now),
      do: {:reply, :ok, %{state | test_now: now + milliseconds}}

  @impl true
  def handle_info(:prune, state) do
    now = now(state)
    schedule_prune(state.prune_interval)
    {:noreply, prune_expired(state, now)}
  end

  defp configured_state(config) do
    values =
      for key <- [:tuple_limit, :source_limit, :window, :max_keys, :prune_interval],
          into: %{},
          do: {key, Keyword.fetch!(config, key)}

    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) and
         values.max_keys >= 2 do
      {:ok, Map.merge(values, %{entries: %{}, test_now: nil})}
    else
      {:stop, {:invalid_configuration, __MODULE__}}
    end
  end

  defp prune_expired(state, now) do
    entries =
      Map.reject(state.entries, fn {_key, {started_at, _count}} ->
        now - started_at >= state.window
      end)

    %{state | entries: entries}
  end

  defp available?(state, key, limit, now) do
    case Map.get(state.entries, key) do
      {started_at, count} when now - started_at < state.window -> count < limit
      nil -> true
      _expired -> true
    end
  end

  defp increment(entries, key, now, window) do
    case Map.get(entries, key) do
      {started_at, count} when now - started_at < window ->
        Map.put(entries, key, {started_at, count + 1})

      _ ->
        Map.put(entries, key, {now, 1})
    end
  end

  defp now(%{test_now: now}) when is_integer(now), do: now
  defp now(_state), do: System.monotonic_time(:millisecond)

  defp schedule_prune(interval), do: Process.send_after(self(), :prune, interval)
end
