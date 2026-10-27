defmodule RengaWeb.AgentChannel do
  @moduledoc """
  One installation's notification channel, `installation:<installation id>`.

  Joining needs a checked-in, active agent, the same condition as leasing.
  The join reply says whether jobs are already waiting, so an agent that
  reconnects catches up at once. After that the channel pushes an empty
  `jobs_waiting` message whenever a job is queued for the agent, and the
  agent answers by calling the HTTPS lease endpoint.

  A socket outlives the request that authenticated it, so the channel checks
  the key, organization and agent again every five
  seconds and closes once any of them is revoked or disabled. Until then a
  revoked key learns only that something is waiting, never what.
  """
  use RengaWeb, :channel

  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Changes

  @recheck_interval :timer.seconds(5)

  @impl true
  def join("installation:" <> installation_id, _payload, socket) do
    with :ok <- own_installation(installation_id, socket),
         {:ok, agent} <- current_agent(socket) do
      scope = socket.assigns.current_scope
      :ok = Changes.subscribe_waiting(scope.organization_id, agent.id)
      schedule_recheck()

      {:ok, %{jobs_waiting: Jobs.jobs_waiting?(scope, agent)},
       assign(socket, :agent_id, agent.id)}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info({:jobs_waiting, agent_id}, %{assigns: %{agent_id: agent_id}} = socket) do
    case current_agent(socket) do
      {:ok, _agent} ->
        push(socket, "jobs_waiting", %{})
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :normal, socket}
    end
  end

  def handle_info(:recheck, socket) do
    case current_agent(socket) do
      {:ok, _agent} ->
        schedule_recheck()
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :normal, socket}
    end
  end

  # The installation ID in the topic must be the one the socket authenticated,
  # compared after normalizing its case.
  defp own_installation(installation_id, socket) do
    case Ecto.UUID.cast(installation_id) do
      {:ok, normalized} when normalized == socket.assigns.current_installation_id ->
        :ok

      _other ->
        {:error, "unauthorized"}
    end
  end

  defp current_agent(socket) do
    %{current_scope: scope, current_intake_api_key: key, current_installation_id: installation} =
      socket.assigns

    case Inventory.with_intake_agent(scope, key, installation, &{:ok, &1}) do
      {:ok, agent} -> {:ok, agent}
      {:error, reason} when is_atom(reason) -> {:error, Atom.to_string(reason)}
    end
  end

  defp schedule_recheck, do: Process.send_after(self(), :recheck, @recheck_interval)
end
