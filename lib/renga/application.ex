defmodule Renga.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RengaWeb.Telemetry,
      Renga.Repo,
      {DNSCluster, query: Application.get_env(:renga, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Renga.PubSub},
      # Start a worker by calling: Renga.Worker.start_link(arg)
      # {Renga.Worker, arg},
      # Start to serve requests, typically the last entry
      RengaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Renga.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RengaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
