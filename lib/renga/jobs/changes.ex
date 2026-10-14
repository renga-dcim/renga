defmodule Renga.Jobs.Changes do
  @moduledoc """
  Tells open pages that an organization's jobs changed, so the Jobs list, a
  job's detail, and a resource's collection banner follow a job as it moves.

  Like `Renga.Inventory.Changes`, the message only says *that* something
  changed; subscribers re-read through `Renga.Jobs`, which applies the usual
  scoping. Broadcasts happen after the change commits. Progress reports can
  arrive often, so subscribers should debounce.

  It also tells a connected agent that work is waiting for it (RFD 9,
  "Phoenix Channels notification"). That notice carries no job content: the
  agent still leases over HTTPS, so a lost notice only delays the job until
  the agent's next check-in.
  """

  alias Renga.Accounts.Scope
  alias Renga.Jobs.Job

  @deferred_key {__MODULE__, :deferred_notices}

  @doc "Subscribes the caller to its organization's job changes."
  def subscribe(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    Phoenix.PubSub.subscribe(Renga.PubSub, topic(organization_id))
  end

  @doc """
  Subscribes the caller to notices that jobs were queued for one agent. The
  caller receives `{:jobs_waiting, agent_id}`.
  """
  def subscribe_waiting(organization_id, agent_id)
      when is_binary(organization_id) and is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Renga.PubSub, waiting_topic(organization_id, agent_id))
  end

  @doc """
  Defers job notifications raised by `operation` until it returns a successful
  result. The outermost caller owns publication, so nested job transactions
  cannot announce work that a surrounding transaction later rolls back.
  """
  def after_commit(operation) when is_function(operation, 0) do
    case Process.get(@deferred_key) do
      %MapSet{} ->
        operation.()

      nil ->
        Process.put(@deferred_key, MapSet.new())

        try do
          result = operation.()
          notices = Process.get(@deferred_key)
          Process.delete(@deferred_key)

          if success?(result), do: Enum.each(notices, &publish/1)
          result
        after
          Process.delete(@deferred_key)
        end
    end
  end

  @doc """
  Announces a change when `result` is a success (any tuple starting with
  `:ok`). A surrounding `after_commit/1` scope holds the notification until
  its outer operation succeeds. Returns `result` unchanged.
  """
  def broadcast(result, organization_id)

  def broadcast(result, organization_id)
      when is_tuple(result) and elem(result, 0) == :ok and is_binary(organization_id) do
    notify({:changed, organization_id})
    result
  end

  def broadcast(result, _organization_id), do: result

  @doc """
  Tells `job`'s agent that the job is waiting to be leased. Call it where a
  job enters `queued`, inside an `after_commit/1` scope: the notice goes out
  only once the surrounding operation succeeds, and is dropped inside a bare
  transaction rather than announcing work that might roll back.
  """
  def job_queued(%Job{state: "queued", organization_id: organization_id, agent_id: agent_id}) do
    notify({:waiting, organization_id, agent_id})
  end

  defp notify(notice) do
    case Process.get(@deferred_key) do
      %MapSet{} = notices -> Process.put(@deferred_key, MapSet.put(notices, notice))
      nil -> unless Renga.Repo.in_transaction?(), do: publish(notice)
    end

    :ok
  end

  defp success?(result), do: is_tuple(result) and elem(result, 0) == :ok

  defp publish({:changed, organization_id}) do
    Phoenix.PubSub.broadcast(
      Renga.PubSub,
      topic(organization_id),
      {:jobs_changed, organization_id}
    )
  end

  defp publish({:waiting, organization_id, agent_id}) do
    Phoenix.PubSub.broadcast(
      Renga.PubSub,
      waiting_topic(organization_id, agent_id),
      {:jobs_waiting, agent_id}
    )
  end

  defp topic(organization_id), do: "jobs:#{organization_id}"

  defp waiting_topic(organization_id, agent_id),
    do: "jobs_waiting:#{organization_id}:#{agent_id}"
end
