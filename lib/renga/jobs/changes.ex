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

  @doc "Subscribes the caller to its organization's job changes."
  def subscribe(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    Phoenix.PubSub.subscribe(Renga.PubSub, topic(organization_id))
  end

  @doc """
  Announces a change when `result` is a success (any tuple starting with
  `:ok`) and no transaction is still open. Returns `result` unchanged.
  """
  def broadcast(result, organization_id)

  def broadcast(result, organization_id)
      when is_tuple(result) and elem(result, 0) == :ok and is_binary(organization_id) do
    unless Renga.Repo.in_transaction?() do
      Phoenix.PubSub.broadcast(
        Renga.PubSub,
        topic(organization_id),
        {:jobs_changed, organization_id}
      )
    end

    result
  end

  def broadcast(result, _organization_id), do: result

  defp topic(organization_id), do: "jobs:#{organization_id}"
end
