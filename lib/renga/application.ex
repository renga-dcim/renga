defmodule Renga.Application do
  @moduledoc """
  Starts the core OTP tree for the Phoenix application.

  Long-running inventory workers and agent schedulers should be added here only
  when they need supervision for the whole application lifetime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RengaWeb.Telemetry,
      Renga.Enrollment.JWKSCache,
      Renga.Enrollment.ChallengeRateLimiter,
      Renga.Repo,
      Renga.Enrollment.Cleanup,
      {DNSCluster, query: Application.get_env(:renga, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Renga.PubSub},
      # Keep the endpoint last so infrastructure dependencies are ready first.
      RengaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Renga.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RengaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
