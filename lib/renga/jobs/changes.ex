defmodule Renga.Jobs.Changes do
  @moduledoc """
  Tells open pages that an organization's jobs changed, so the Jobs list, a
  job's detail, and a resource's collection banner follow a job as it moves.

  Like `Renga.Inventory.Changes`, the message only says *that* something
  changed; subscribers re-read through `Renga.Jobs`, which applies the usual
  scoping. Broadcasts happen after the change commits. Progress reports can
  arrive often, so subscribers should debounce.
  """

  alias Renga.Accounts.Scope

  @deferred_key {__MODULE__, :deferred_organizations}

  @doc "Subscribes the caller to its organization's job changes."
  def subscribe(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    Phoenix.PubSub.subscribe(Renga.PubSub, topic(organization_id))
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
          organizations = Process.get(@deferred_key)
          Process.delete(@deferred_key)

          if success?(result), do: Enum.each(organizations, &publish/1)
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
    case Process.get(@deferred_key) do
      %MapSet{} = organizations ->
        Process.put(@deferred_key, MapSet.put(organizations, organization_id))

      nil ->
        unless Renga.Repo.in_transaction?(), do: publish(organization_id)
    end

    result
  end

  def broadcast(result, _organization_id), do: result

  defp success?(result), do: is_tuple(result) and elem(result, 0) == :ok

  defp publish(organization_id) do
    Phoenix.PubSub.broadcast(
      Renga.PubSub,
      topic(organization_id),
      {:jobs_changed, organization_id}
    )
  end

  defp topic(organization_id), do: "jobs:#{organization_id}"
end
