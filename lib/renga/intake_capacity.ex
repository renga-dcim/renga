defmodule Renga.IntakeCapacity do
  @moduledoc """
  Fail-fast, per-node intake lanes. No admitted request waits for another
  request's permit. Permits follow the request process through reconciliation
  and are reclaimed if it crashes. Bulk and new leases cannot borrow the
  maintenance reserve. Counters and pending contacts have bounded cardinality.
  """
  use GenServer

  alias Renga.Limits

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def acquire(key, limit), do: GenServer.call(__MODULE__, {:acquire, self(), key, limit})
  def release(ref), do: GenServer.call(__MODULE__, {:release, ref})

  def authentication(fun, lane \\ :bulk) do
    case acquire({:authentication, lane}, lane_size(:authentication)) do
      {:ok, ref} ->
        try do
          fun.()
        after
          release(ref)
        end

      :full ->
        {:error, :capacity}
    end
  end

  def lane_size(:authentication), do: max(div(pool_size(), 8), 1)
  # Reserve connections for lease sweeping, archive generation, other background
  # work, and the contact recorder before splitting domain capacity. Authentication lanes
  # and the remaining headroom are outside these domain permits.
  def lane_size(lane) when lane in [:bulk, :maintenance],
    do: max(div(pool_size() - 4, 3), 1)

  def organization_size, do: max(div(lane_size(:bulk), 2), 1)

  defp pool_size, do: Renga.Repo.config()[:pool_size] || 10

  def admit(organization_id, installation_id, lane, limits) do
    GenServer.call(
      __MODULE__,
      {:admit, self(), organization_id, installation_id, lane, limits}
    )
  end

  def contact(key, installation_id) do
    GenServer.call(
      __MODULE__,
      {:contact, key.organization_id, installation_id, Renga.Time.utc_now_ms()}
    )
  end

  @doc "Drains at most one contact batch; timestamps are authentication time, not flush time."
  def flush_contacts do
    batch = GenServer.call(__MODULE__, :contacts)

    try do
      Renga.Inventory.record_intake_contacts(batch)
    rescue
      error ->
        for {org, installation, at} <- batch do
          GenServer.call(__MODULE__, {:contact, org, installation, at})
        end

        reraise error, __STACKTRACE__
    end

    :ok
  end

  def limits(organization_id) do
    Limits.get_all(organization_id)
  end

  def bulk_usage(org), do: GenServer.call(__MODULE__, {:usage, org, :bulk})
  def maintenance_usage(org), do: GenServer.call(__MODULE__, {:usage, org, :maintenance})
  def installation_usage(org), do: GenServer.call(__MODULE__, {:usage, org, :installation})
  def concurrency_usage(org), do: GenServer.call(__MODULE__, {:usage, org, :concurrency})

  @doc false
  def database_time([:renga, :repo, :query], measurements, _metadata, _config) do
    if organization_id = Process.get(:intake_organization_id) do
      :telemetry.execute([:renga, :intake, :database], measurements, %{
        organization_id: organization_id
      })
    end
  end

  def database_time(_event, _measurements, _metadata, _config),
    do: Process.delete(:intake_organization_id)

  @impl true
  def init(_options) do
    :telemetry.attach_many(
      "renga-intake-database",
      [[:renga, :repo, :query], [:phoenix, :endpoint, :stop], [:phoenix, :endpoint, :exception]],
      &__MODULE__.database_time/4,
      nil
    )

    {:ok,
     %{
       permits: %{},
       counts: %{},
       rates: %{},
       window: nil,
       contacts: %{},
       contact_counts: %{},
       contact_queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:acquire, pid, key, limit}, _from, state) do
    if Map.get(state.counts, key, 0) < limit do
      {ref, state} = permit(state, pid, [key])
      {:reply, {:ok, ref}, state}
    else
      {:reply, :full, state}
    end
  end

  def handle_call({:admit, pid, org, installation, class, limits}, _from, state) do
    lane = if class == :lease, do: :bulk, else: class
    now = System.monotonic_time(:second)
    window = Integer.floor_div(now, 60)
    rates = if state.window == window, do: state.rates, else: %{}
    state = %{state | rates: rates, window: window}
    rate_name = if lane == :maintenance, do: :intake_maintenance_rate, else: :intake_bulk_rate
    organization_limit = min(limits.intake_concurrency, organization_size())

    rate_keys = [
      {{:organization, org, lane}, limits[rate_name]},
      {{:installation, org, installation, lane}, limits.installation_intake_rate}
    ]

    keys = [{:lane, lane}, {:organization, org, lane}]
    installation_key = {:installation, org, installation, lane}
    new_installation? = not Map.has_key?(rates, installation_key)
    {_, installation_count} = Map.get(rates, {:keys, org}, {window, 0})

    rate_available? =
      Enum.all?(rate_keys, fn {key, limit} ->
        {_window, count} = Map.get(rates, key, {window, 0})
        count < limit
      end)

    {_, maintenance_used} = Map.get(rates, {:organization, org, :maintenance}, {window, 0})

    lease_headroom? =
      class != :lease or
        (maintenance_used * 2 < limits.intake_maintenance_rate and
           Map.get(state.counts, {:organization, org, :maintenance}, 0) <
             organization_limit)

    available? =
      Map.get(state.counts, {:lane, lane}, 0) < lane_size(lane) and
        Map.get(state.counts, {:organization, org, lane}, 0) < organization_limit and
        map_size(rates) < 100_000 and
        (not new_installation? or installation_count < 20_000) and rate_available? and
        lease_headroom?

    if available? do
      rates =
        Enum.reduce(rate_keys, rates, fn {key, _limit}, rates ->
          Map.update(rates, key, {window, 1}, fn {_, count} -> {window, count + 1} end)
        end)

      rates =
        if new_installation?,
          do: Map.put(rates, {:keys, org}, {window, installation_count + 1}),
          else: rates

      {ref, state} = permit(%{state | rates: rates}, pid, keys)
      {:reply, {:ok, ref}, state}
    else
      reason =
        cond do
          not rate_available? ->
            :rate

          not lease_headroom? ->
            :lease_reserve

          Map.get(state.counts, {:lane, lane}, 0) >= lane_size(lane) ->
            :node_concurrency

          Map.get(state.counts, {:organization, org, lane}, 0) >= organization_limit ->
            :organization_concurrency

          true ->
            :cardinality
        end

      :telemetry.execute([:renga, :intake, :admission_rejected], %{count: 1}, %{
        organization_id: org,
        lane: lane,
        reason: reason
      })

      {:reply, {:error, if(rate_available?, do: 1, else: 60 - Integer.mod(now, 60))}, state}
    end
  end

  def handle_call({:release, ref}, _from, state), do: {:reply, :ok, drop(state, ref)}

  def handle_call({:usage, org, kind}, _from, state) do
    rates =
      if state.window == Integer.floor_div(System.monotonic_time(:second), 60),
        do: state.rates,
        else: %{}

    value =
      case kind do
        :concurrency ->
          max(
            Map.get(state.counts, {:organization, org, :bulk}, 0),
            Map.get(state.counts, {:organization, org, :maintenance}, 0)
          )

        :installation ->
          Enum.reduce(rates, 0, fn
            {{:installation, ^org, _id, _lane}, {_window, count}}, peak -> max(peak, count)
            _, peak -> peak
          end)

        lane ->
          rates |> Map.get({:organization, org, lane}, {0, 0}) |> elem(1)
      end

    {:reply, value, state}
  end

  def handle_call({:contact, org, installation, at}, _from, state) do
    key = {org, installation}
    contacts = state.contacts
    # A caller with a valid shared key can invent installation UUIDs; never
    # allow those to grow the recorder without bound.
    state =
      cond do
        Map.has_key?(contacts, key) ->
          %{
            state
            | contacts:
                Map.update!(contacts, key, fn previous ->
                  if DateTime.after?(at, previous), do: at, else: previous
                end)
          }

        map_size(contacts) < 100_000 and Map.get(state.contact_counts, org, 0) < 10_000 ->
          %{
            state
            | contacts: Map.put(contacts, key, at),
              contact_queue: :queue.in(key, state.contact_queue),
              contact_counts: Map.update(state.contact_counts, org, 1, &(&1 + 1))
          }

        true ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(:contacts, _from, state) do
    size = min(:queue.len(state.contact_queue), 1_000)
    {batch, queue} = :queue.split(size, state.contact_queue)
    keys = :queue.to_list(batch)
    batch = Enum.map(keys, fn {org, id} = key -> {org, id, Map.fetch!(state.contacts, key)} end)

    counts =
      Enum.reduce(keys, state.contact_counts, fn {org, _id}, counts ->
        case counts[org] do
          1 -> Map.delete(counts, org)
          n -> Map.put(counts, org, n - 1)
        end
      end)

    {:reply, batch,
     %{
       state
       | contacts: Map.drop(state.contacts, keys),
         contact_queue: queue,
         contact_counts: counts
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, drop(state, ref)}

  defp permit(state, pid, keys) do
    ref = Process.monitor(pid)
    counts = Enum.reduce(keys, state.counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))
    {ref, %{state | counts: counts, permits: Map.put(state.permits, ref, keys)}}
  end

  defp drop(state, ref) do
    Process.demonitor(ref, [:flush])
    {keys, permits} = Map.pop(state.permits, ref, [])

    counts =
      Enum.reduce(keys, state.counts, fn key, counts ->
        case Map.fetch!(counts, key) do
          1 -> Map.delete(counts, key)
          n -> Map.put(counts, key, n - 1)
        end
      end)

    %{state | permits: permits, counts: counts}
  end
end
