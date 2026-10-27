defmodule Renga.Operators.LifecycleListener do
  @moduledoc """
  Bridges committed lifecycle changes from repository-only release commands
  to local sockets on each application node. Authorization still re-reads the
  database at every boundary; NOTIFY is prompt invalidation, not authority.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    opts = Renga.Repo.config() |> Keyword.delete(:name) |> Keyword.put(:auto_reconnect, true)
    {:ok, connection} = Postgrex.Notifications.start_link(opts)

    {_status, reference} =
      Postgrex.Notifications.listen(connection, "renga_organization_lifecycle")

    {:ok, %{connection: connection, reference: reference}}
  end

  @impl true
  def handle_info(
        {:notification, connection, reference, "renga_organization_lifecycle", id},
        %{connection: connection, reference: reference} = state
      ) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Renga.Operators.OrganizationLifecycle.publish(id)
    {:noreply, state}
  end
end
