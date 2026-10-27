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
    plug RengaWeb.RecoveryMode
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :intake_api do
    plug RengaWeb.IntakeAuth
  end

  # SCIM provisioning (RFD 16). No session: only a connection's bearer token
  # reaches these routes.
  pipeline :scim do
    plug RengaWeb.Scim.Auth
    plug RengaWeb.Scim.RateLimit
  end

  scope "/", RengaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Unauthenticated: an agent asks where its home deployment is before it
  # sends its intake key anywhere (RFD 23).
  scope "/api/v1", RengaWeb.Api.V1 do
    pipe_through :api

    get "/agent/home", AgentHomeController, :show
  end

  scope "/api/v1", RengaWeb.Api.V1 do
    pipe_through [:api, :intake_api]

    post "/agent/checkins", AgentController, :check_in
    post "/agent/jobs/lease", JobController, :lease
    post "/agent/jobs/:id/claims", JobController, :claim
    post "/agent/jobs/:id/events", JobController, :create_event
    post "/observations", ObservationController, :create
    post "/telemetry", TelemetryController, :create
  end

  # Route dispatch logging is off here: it prints request parameters, and
  # Phoenix's filter misses a SCIM password sent as a PATCH operation's
  # value or under a key such as "Password" (RFD 16 never logs one).
  scope "/scim/v2", RengaWeb.Scim, log: false do
    pipe_through :scim

    get "/ServiceProviderConfig", DiscoveryController, :service_provider_config
    get "/ResourceTypes", DiscoveryController, :resource_types
    get "/ResourceTypes/:id", DiscoveryController, :resource_type
    get "/Schemas", DiscoveryController, :schemas
    get "/Schemas/:id", DiscoveryController, :schema
    get "/Users", UserController, :index
    post "/Users", UserController, :create
    get "/Users/:id", UserController, :show
    put "/Users/:id", UserController, :update
    patch "/Users/:id", UserController, :patch
    delete "/Users/:id", UserController, :delete
    get "/Groups", GroupController, :index
    post "/Groups", GroupController, :create
    get "/Groups/:id", GroupController, :show
    put "/Groups/:id", GroupController, :update
    patch "/Groups/:id", GroupController, :patch
    delete "/Groups/:id", GroupController, :delete
    match :*, "/Me", DiscoveryController, :me
    match :*, "/Me/*path", DiscoveryController, :me
    match :*, "/*path", DiscoveryController, :not_found
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

    # Machine API reference: the live OpenAPI document and a Redoc page for it.
    scope "/dev/api" do
      get "/openapi.json", Oaskit.SpecController, spec: RengaWeb.ApiSpec
      get "/", Oaskit.SpecController, redoc: "/dev/api/openapi.json"
    end
  end

  # The living design system (docs/design-system.md). It shows sample data
  # only, so it needs no sign-in; test builds compile it for its own tests.
  if Application.compile_env(:renga, :dev_routes) ||
       Application.compile_env(:renga, :test_routes) do
    scope "/dev", RengaWeb do
      pipe_through :browser

      live "/design-system", DesignSystemLive
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
        RengaWeb.RecoveryMode,
        {RengaWeb.UserAuth, :require_authenticated},
        RengaWeb.AccessHook,
        RengaWeb.SidebarViews,
        RengaWeb.AppearanceHook
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/organizations", OrganizationLive.Index, :index
      live "/organizations/confirm-mfa", OrganizationLive.ConfirmMFA, :show
      live "/invitations/:token", InvitationLive, :show

      # The six RFD 8 areas.
      live "/inbox", InboxLive, :index

      live "/inventory", ResourceLive.Index, :index
      live "/inventory/:id", ResourceLive.Show, :show
      live "/inventory/:id/hardware", ResourceHardwareLive, :show
      live "/inventory/:id/ports", ResourcePortsLive, :show
      live "/inventory/:id/power", ResourcePowerLive, :show
      live "/inventory/:id/network", ResourceLive.Show, :network
      live "/inventory/:id/queries", ResourceQueriesLive, :show
      live "/inventory/:id/sources", ResourceLive.Show, :sources
      live "/inventory/:id/activity", ResourceLive.Show, :activity

      live "/places", DcimLive, :sites
      live "/places/sites/:id", DcimLive, :site
      live "/places/sites/:id/power", SitePowerLive, :show
      live "/places/locations/:id", DcimLive, :location
      live "/places/racks", DcimLive, :racks
      live "/places/racks/:id", RackLive, :show

      live "/network/topology", TopologyLive, :index
      live "/network/vlans", VlanLive, :index
      live "/network/vlans/:id", VlanDetailLive, :show
      live "/network/vlan-groups", VlanGroupLive, :index
      live "/network/prefixes", PrefixLive, :index
      live "/network/prefixes/:id", PrefixDetailLive, :show
      live "/network/vrfs", VrfLive, :index
      live "/network/addresses", AddressLive, :index
      live "/network/cables", CableLive, :index

      live "/activity", ActivityLive, :index
      live "/activity/jobs", JobsLive, :index
      live "/activity/jobs/:id", JobsLive, :show
      live "/activity/queries/:batch_id", QueryBatchLive, :show

      live "/catalog/hardware-types", CatalogLive, :hardware_types
      live "/catalog/hardware-types/:id", CatalogLive, :hardware_type
      live "/catalog/hardware-types/:id/draft", CatalogDraftLive, :edit
      live "/catalog/module-types", CatalogLive, :module_types
      live "/catalog/module-types/:id", CatalogLive, :module_type
      live "/catalog/manufacturers", CatalogLive, :manufacturers

      live "/settings/collectors", InventoryOperationsLive, :index
      live "/settings/members", MemberLive, :index
      live "/settings/roles", RoleLive, :index
      live "/settings/teams", TeamLive, :index
      live "/settings/scim", ScimLive, :index
      live "/settings/groups", GroupLive, :index
      live "/settings/triage-rules", TriageRuleLive, :index
      live "/settings/appearance", AppearanceLive, :index
      live "/settings/limits", LimitsLive, :index
      live "/settings/identity-providers", OrganizationProviderLive, :index
      live "/settings/queries", QuerySettingsLive, :index
      live "/settings/security", SecurityLive, :index
      live "/settings/export", ExportLive, :index
      live "/settings/import", ImportLive, :index
    end

    get "/settings/export/:id/download", ExportController, :download

    # Recovery authenticates a person, but deliberately does not require or
    # select an active tenant. Each operation rechecks the pending tenant's owner.
    get "/organizations/deletions", DeletionController, :index
    post "/organizations/deletions/:id/cancel", DeletionController, :cancel
    post "/organizations/deletions/:id/export", DeletionController, :export
    get "/organizations/deletions/:id/exports/:export_id", DeletionController, :download

    post "/organizations/select", OrganizationSessionController, :create
    post "/organizations/confirm-mfa", OrganizationSessionController, :confirm_mfa
    post "/users/update-password", UserSessionController, :update_password
    post "/users/settings/identities", UserProviderController, :link
    post "/users/settings/recheck", UserProviderController, :recheck
  end

  scope "/", RengaWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        RengaWeb.SQLSandbox,
        RengaWeb.RecoveryMode,
        {RengaWeb.UserAuth, :mount_current_scope},
        RengaWeb.AppearanceHook
      ] do
      live "/recovery", RecoveryLive, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/second-step", UserLive.SecondStep, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/log-in/second-step", UserSessionController, :second_step
    post "/users/log-in/passkey", UserSessionController, :passkey
    get "/users/log-in/provider/:provider", UserProviderController, :start
    get "/users/auth/:provider/callback", UserProviderController, :callback
    # Not logged: the path and its parameters are the test's bearer token.
    get "/users/providers/test/:token", UserProviderController, :test, log: false
    delete "/users/log-out", UserSessionController, :delete
  end
end
