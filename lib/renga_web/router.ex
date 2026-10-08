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

  pipeline :intake_api do
    plug RengaWeb.IntakeAuth
  end

  scope "/", RengaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api/v1", RengaWeb.Api.V1 do
    pipe_through [:api, :intake_api]

    post "/agent/checkins", AgentController, :check_in
    post "/observations", ObservationController, :create
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

  # Fixture pages from test/support that browser tests drive, such as the
  # shared component review page. Only test builds compile these routes.
  if Application.compile_env(:renga, :test_routes) do
    scope "/test", RengaWeb do
      pipe_through :browser

      live_session :test_fixtures, on_mount: [RengaWeb.SQLSandbox] do
        live "/ui-review", UIReviewLive
      end
    end
  end

  # Entry points and retired URLs. Declared before the area routes so that
  # literal paths such as /inventory/resources win over /inventory/:id. The
  # targets require sign-in themselves, so these need only the browser
  # pipeline.
  scope "/", RengaWeb do
    pipe_through :browser

    get "/network", RedirectController, :show, assigns: %{to: "/network/topology", status: :found}

    get "/catalog", RedirectController, :show,
      assigns: %{to: "/catalog/hardware-types", status: :found}

    get "/settings", RedirectController, :show,
      assigns: %{to: "/settings/collectors", status: :found}

    get "/inventory/resources", RedirectController, :show, assigns: %{to: "/inventory"}
    get "/inventory/resources/:id", RedirectController, :show, assigns: %{to: "/inventory/:id"}

    get "/inventory/resources/:id/hardware", RedirectController, :show,
      assigns: %{to: "/inventory/:id/hardware"}

    get "/inventory/component-findings", RedirectController, :show,
      assigns: %{to: "/inbox?domain=component"}

    # The per-domain findings pages became one Inbox queue.
    get "/inbox/components", RedirectController, :show, assigns: %{to: "/inbox?domain=component"}
    get "/inbox/topology", RedirectController, :show, assigns: %{to: "/inbox?domain=topology"}
    get "/inbox/placement", RedirectController, :show, assigns: %{to: "/inbox?domain=placement"}

    get "/inventory/operations", RedirectController, :show, assigns: %{to: "/settings/collectors"}

    get "/network/topology-findings", RedirectController, :show,
      assigns: %{to: "/inbox?domain=topology"}

    get "/dcim/placement-findings", RedirectController, :show,
      assigns: %{to: "/inbox?domain=placement"}

    get "/dcim/sites", RedirectController, :show, assigns: %{to: "/places"}
    get "/dcim/sites/:id", RedirectController, :show, assigns: %{to: "/places/sites/:id"}
    get "/dcim/locations/:id", RedirectController, :show, assigns: %{to: "/places/locations/:id"}
    get "/dcim/racks", RedirectController, :show, assigns: %{to: "/places/racks"}
    get "/dcim/racks/:id", RedirectController, :show, assigns: %{to: "/places/racks/:id"}

    get "/dcim/manufacturers", RedirectController, :show, assigns: %{to: "/catalog/manufacturers"}

    get "/dcim/hardware-types", RedirectController, :show,
      assigns: %{to: "/catalog/hardware-types"}

    get "/dcim/hardware-types/:id", RedirectController, :show,
      assigns: %{to: "/catalog/hardware-types/:id"}

    get "/dcim/module-types", RedirectController, :show, assigns: %{to: "/catalog/module-types"}

    get "/dcim/module-types/:id", RedirectController, :show,
      assigns: %{to: "/catalog/module-types/:id"}

    get "/ipam/vlans", RedirectController, :show, assigns: %{to: "/network/vlans"}
    get "/ipam/vlan-groups", RedirectController, :show, assigns: %{to: "/network/vlan-groups"}
  end

  ## Authentication routes

  scope "/", RengaWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        RengaWeb.SQLSandbox,
        {RengaWeb.UserAuth, :require_authenticated},
        RengaWeb.SidebarViews
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/organizations", OrganizationLive.Index, :index

      # The six RFD 8 areas.
      live "/inbox", InboxLive, :index

      live "/inventory", ResourceLive.Index, :index
      live "/inventory/:id", ResourceLive.Show, :show
      live "/inventory/:id/hardware", ResourceHardwareLive, :show
      live "/inventory/:id/network", ResourceLive.Show, :network
      live "/inventory/:id/sources", ResourceLive.Show, :sources
      live "/inventory/:id/activity", ResourceLive.Show, :activity

      live "/places", DcimLive, :sites
      live "/places/sites/:id", DcimLive, :site
      live "/places/locations/:id", DcimLive, :location
      live "/places/racks", DcimLive, :racks
      live "/places/racks/:id", DcimLive, :rack

      live "/network/topology", TopologyLive, :index
      live "/network/vlans", VlanLive, :index
      live "/network/vlan-groups", VlanGroupLive, :index
      live "/network/cables", CableLive, :index

      live "/activity", ActivityLive, :index

      live "/catalog/hardware-types", CatalogLive, :hardware_types
      live "/catalog/hardware-types/:id", CatalogLive, :hardware_type
      live "/catalog/module-types", CatalogLive, :module_types
      live "/catalog/module-types/:id", CatalogLive, :module_type
      live "/catalog/manufacturers", CatalogLive, :manufacturers

      live "/settings/collectors", InventoryOperationsLive, :index
    end

    post "/organizations/select", OrganizationSessionController, :create
    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", RengaWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [RengaWeb.SQLSandbox, {RengaWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
