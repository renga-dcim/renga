defmodule Renga.Inventory.ReconciliationWorker do
  @moduledoc """
  One independently supervised reconciliation slot per node. The database lane
  fences organization ownership across nodes and persists fair turn rotation.
  Periodic rediscovery is sufficient: neither request processes nor wakeups own work.
  """
  use GenServer
  require Logger

  alias Renga.Inventory.ReconciliationWork, as: Work

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 1_000)
    send(self(), :poll)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    result = run_once(wait_ms: 0)
    delay = if result in [{:ok, :idle}, {:ok, :busy}], do: state.interval, else: 10
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  @doc "Claims and processes at most one organization head, using only committed database state."
  def run_once(opts \\ []) do
    # Immediate operator calls and the supervised poller share this one slot.
    # Caller death releases the local permit; the database claim remains fenced
    # until expiry and is rediscovered by supervision, not abandoned or debited.
    deadline =
      System.monotonic_time(:millisecond) + min(Keyword.get(opts, :wait_ms, 35_000), 35_000)

    case acquire_slot(deadline) do
      {:ok, permit} ->
        try do
          case Work.claim_next(opts) do
            {:ok, claim} when is_map(claim) -> process(claim, opts)
            result -> result
          end
        after
          Renga.IntakeCapacity.release(permit)
        end

      :full ->
        {:ok, :busy}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("Reconciliation rediscovery unavailable: #{inspect(error.__struct__)}")
      {:error, :database_unavailable}
  end

  # Waiting callers hold neither a connection nor a claim. Intake never waits
  # here; only explicit maintenance/operator calls may wait for the bounded slot.
  defp acquire_slot(deadline) do
    case Renga.IntakeCapacity.acquire(:reconciliation, 1) do
      :full ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          acquire_slot(deadline)
        else
          :full
        end

      permit ->
        permit
    end
  end

  defp process(claim, opts) do
    result =
      try do
        Work.execute_report(claim, opts)
      rescue
        error -> {:error, error}
      end

    case result do
      {:ok, value} ->
        Renga.Inventory.Changes.broadcast(value, claim.organization_id)
        result

      {:error, reason} when reason in [:stale_claim, :expired_claim, :forbidden] ->
        result

      {:error, reason} ->
        {kind, error, delay} = failure(reason)

        case Work.fail(claim, kind, error, backoff_ms: delay, record_attempt: true) do
          {:ok, work} ->
            scope = %Renga.Accounts.Scope{organization_id: work.organization_id}
            observation = Renga.Inventory.get_observation!(scope, work.observation_id)
            {:ok, Renga.Inventory.Reconciler.stored_result(scope, observation)}

          error ->
            error
        end
    end
  end

  defp failure({:turn_failed, reason}), do: failure(reason)
  defp failure({:resource_failed, _observation, reason}), do: failure(reason)

  defp failure(reason) do
    cond do
      Renga.Quotas.exceeded?(reason, :resources) ->
        # Periodic rediscovery covers missed deletion/limit-change notifications
        # and restarts. This is a scheduling bound, not capacity evidence.
        {:quota, %{"processing" => "quota_deferred", "quota" => "resources"}, 30_000}

      transient?(reason) ->
        {:backoff, %{"processing" => "projection_failed"}, 1_000}

      true ->
        {:domain, %{"processing" => "projection_failed"}, 0}
    end
  end

  defp transient?(%DBConnection.ConnectionError{}), do: true

  defp transient?(%Postgrex.Error{postgres: %{code: code}}),
    do:
      code in [
        :serialization_failure,
        :deadlock_detected,
        :query_canceled,
        :lock_not_available,
        :admin_shutdown,
        :cannot_connect_now,
        :too_many_connections
      ]

  defp transient?(_reason), do: false
end
