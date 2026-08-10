defmodule RengaWeb.Router do
  use RengaWeb, :router

  import RengaWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RengaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :source_api do
    plug RengaWeb.SourceAuth
  end

  pipeline :agent_credential_api do
    plug RengaWeb.AgentCredentialAuth
  end

  scope "/", RengaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api/v1", RengaWeb.Api.V1 do
    pipe_through [:api, :source_api]

    post "/agent/checkins", AgentController, :check_in
    post "/observations", ObservationController, :create
  end

  scope "/api/v1/key", RengaWeb.Api.V1 do
    # Key authentication is deliberately isolated from legacy bearer migration routes.
    pipe_through [:api, :agent_credential_api]

    post "/agent/checkins", AgentController, :check_in
    post "/observations", ObservationController, :create
    post "/agent/credentials/renew", AgentCredentialController, :renew
  end

  scope "/api/v1/enrollment", RengaWeb.Api.V1 do
    # Enrollment proves a new key and must never inherit human or Source authentication.
    pipe_through :api

    post "/challenges", EnrollmentController, :challenge
    post "/attempts", EnrollmentController, :attempt
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:renga, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RengaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", RengaWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{RengaWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/organizations", OrganizationLive.Index, :index

      live "/inventory", InventoryDashboardLive, :index
      live "/inventory/resources", ResourceLive.Index, :index
      live "/inventory/resources/:id", ResourceLive.Show, :show
      live "/inventory/operations", InventoryOperationsLive, :index
    end

    post "/organizations/select", OrganizationSessionController, :create
    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", RengaWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{RengaWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
