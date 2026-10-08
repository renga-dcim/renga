defmodule Renga.Inventory.Changes do
  @moduledoc """
  Tells open pages that an organization's inventory changed, so lists and
  object pages update without a refresh control (RFD 8: live updates).

  The message only says *that* something changed; subscribers re-read through
  the context, which applies the usual scoping. Nothing about the change
  itself travels over PubSub. Broadcasts happen after the change commits;
  a subscriber should debounce, since one collector report can touch many
  resources.
  """

  alias Renga.Accounts.Scope

  @doc "Subscribes the caller to its organization's inventory changes."
  def subscribe(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    Phoenix.PubSub.subscribe(Renga.PubSub, topic(organization_id))
  end

  @doc """
  Announces a change. Returns `result` unchanged so it can end a pipeline,
  and only announces when `result` is a success (any tuple starting with
  `:ok`).
  """
  def broadcast(result, organization_id)

  def broadcast(result, organization_id)
      when is_tuple(result) and elem(result, 0) == :ok and is_binary(organization_id) do
    # Nested mutations cannot announce a commit. Their transaction-owning
    # context publishes after the enclosing transaction succeeds.
    unless Renga.Repo.in_transaction?() do
      Phoenix.PubSub.broadcast(
        Renga.PubSub,
        topic(organization_id),
        {:inventory_changed, organization_id}
      )
    end

    result
  end

  def broadcast(result, _organization_id), do: result

  defp topic(organization_id), do: "inventory:#{organization_id}"
end
