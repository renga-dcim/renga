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
    # A telemetry store that cannot serve range reads fails the boot too.
    Renga.Telemetry.Store.adapter!()

    children =
      [
        RengaWeb.Telemetry,
        Renga.Repo,
        {DNSCluster, query: Application.get_env(:renga, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Renga.PubSub},
        Renga.Accounts.OIDC.Discovery,
        neighbor_expiry_worker(),
        same_machine_sweeper(),
        collector_findings_worker(),
        assignment_expiry_worker(),
        organization_domain_worker(),
        job_sweeper(),
        job_history_purger(),
        invitation_delivery_worker(),
        power_finding_sweeper(),
        telemetry_pruner(),
        RengaWeb.Scim.RateLimit.Table,
        # Keep the endpoints last so infrastructure dependencies are ready first.
        RengaWeb.Endpoint,
        RengaWeb.OperatorEndpoint
      ]
      |> Enum.reject(&is_nil/1)

    :ok = RengaWeb.OperatorListener.load_revocation_list()

    opts = [strategy: :one_for_one, name: Renga.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RengaWeb.Endpoint.config_change(changed, removed)
    RengaWeb.OperatorEndpoint.config_change(changed, removed)
    :ok
  end

  defp neighbor_expiry_worker do
    if Application.get_env(:renga, :neighbor_expiry_worker_enabled, true),
      do: Renga.Topology.NeighborExpiryWorker
  end

  defp same_machine_sweeper do
    if Application.get_env(:renga, :same_machine_sweeper_enabled, true),
      do: Renga.Inventory.SameMachineSweeper
  end

  defp collector_findings_worker do
    if Application.get_env(:renga, :collector_findings_worker_enabled, true),
      do: Renga.Inventory.CollectorFindingsWorker
  end

  defp job_sweeper do
    if Application.get_env(:renga, :job_sweeper_enabled, true), do: Renga.Jobs.Sweeper
  end

  defp job_history_purger do
    if Application.get_env(:renga, :job_sweeper_enabled, true), do: Renga.Jobs.HistoryPurger
  end

  defp power_finding_sweeper do
    if Application.get_env(:renga, :power_finding_sweeper_enabled, true),
      do: Renga.Power.FindingSweeper
  end

  defp telemetry_pruner do
    if Application.get_env(:renga, :telemetry_pruner_enabled, true), do: Renga.Telemetry.Pruner
  end

  defp organization_domain_worker do
    if Application.get_env(:renga, :organization_domain_worker_enabled, true),
      do: Renga.Accounts.OrganizationDomains.Worker
  end

  defp assignment_expiry_worker do
    if Application.get_env(:renga, :assignment_expiry_worker_enabled, true),
      do: Renga.Assignments.ExpiryWorker
  end

  defp invitation_delivery_worker do
    if Application.get_env(:renga, :invitation_delivery_worker_enabled, true),
      do: Renga.Operators.InvitationDeliveryWorker
  end
end
