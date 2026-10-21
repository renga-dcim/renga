defmodule Renga.Application do
  @moduledoc """
  Starts the core OTP tree for the Phoenix application.

  Long-running inventory workers and agent schedulers should be added here only
  when they need supervision for the whole application lifetime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # A malformed ENCRYPTION_KEYS fails the boot rather than the first secret.
    Renga.Vault.keys()

    children =
      [
        RengaWeb.Telemetry,
        Renga.Repo,
        {DNSCluster, query: Application.get_env(:renga, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Renga.PubSub},
        neighbor_expiry_worker(),
        assignment_expiry_worker(),
        job_sweeper(),
        # Keep the endpoint last so infrastructure dependencies are ready first.
        RengaWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Renga.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RengaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp neighbor_expiry_worker do
    if Application.get_env(:renga, :neighbor_expiry_worker_enabled, true),
      do: Renga.Topology.NeighborExpiryWorker
  end

  defp job_sweeper do
    if Application.get_env(:renga, :job_sweeper_enabled, true), do: Renga.Jobs.Sweeper
  end

  defp assignment_expiry_worker do
    if Application.get_env(:renga, :assignment_expiry_worker_enabled, true),
      do: Renga.Assignments.ExpiryWorker
  end
end
