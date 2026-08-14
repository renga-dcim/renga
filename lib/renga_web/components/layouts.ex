defmodule RengaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RengaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active_nav, :atom,
    default: nil,
    values: [nil, :overview, :resources, :collectors],
    doc: "the active inventory navigation destination"

  attr :content_class, :string, default: "p-6", doc: "classes for the authenticated workspace"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div :if={@current_scope && @current_scope.organization_id} class="flex min-h-screen bg-base-100">
      <aside
        id="app-sidebar"
        class="sticky top-0 flex h-screen w-56 shrink-0 flex-col border-r border-base-content/10 bg-base-200/45 px-3 py-4"
      >
        <.link
          navigate={~p"/inventory"}
          class="flex h-10 items-center gap-2.5 px-2 text-sm font-semibold tracking-tight"
          aria-label="Renga overview"
        >
          <span class="grid size-7 place-items-center text-orange-600">
            <.icon name="hero-server-stack-solid" class="size-6" />
          </span>
          <span class="text-base">Renga</span>
        </.link>

        <.link
          id="organization-switcher"
          navigate={~p"/organizations"}
          class="mt-3 flex h-10 items-center gap-2 rounded-md border border-base-content/10 bg-base-100 px-2.5 text-xs font-medium transition hover:border-base-content/20 hover:bg-base-200"
        >
          <.icon name="hero-cube" class="size-4 text-base-content/55" />
          <span class="min-w-0 flex-1 truncate">{@current_scope.organization.name}</span>
          <.icon name="hero-chevron-up-down" class="size-3.5 text-base-content/40" />
        </.link>

        <button
          id="command-palette-trigger"
          type="button"
          class="mt-3 flex h-10 w-full items-center gap-2 rounded-md border border-base-content/10 bg-base-100 px-2.5 text-left text-xs text-base-content/60 transition hover:border-base-content/20 hover:text-base-content"
          phx-click={JS.dispatch("renga:open-command-palette")}
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
          <span class="flex-1">Search</span>
          <kbd class="rounded border border-base-content/10 bg-base-200 px-1.5 py-0.5 font-mono text-[10px] text-base-content/45">
            Ctrl K
          </kbd>
        </button>

        <nav id="primary-navigation" class="mt-5 space-y-1" aria-label="Primary navigation">
          <.sidebar_link
            navigate={~p"/inventory"}
            icon="hero-home"
            label="Overview"
            active?={@active_nav == :overview}
          />
          <.sidebar_link
            navigate={~p"/inventory/resources"}
            icon="hero-cube"
            label="Resources"
            active?={@active_nav == :resources}
          />
          <.sidebar_link
            navigate={~p"/inventory/operations"}
            icon="hero-circle-stack"
            label="Collectors"
            active?={@active_nav == :collectors}
          />
        </nav>

        <div class="mt-5 border-t border-base-content/10 pt-5">
          <p class="px-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-base-content/40">
            Saved views
          </p>
          <nav class="mt-2 space-y-1" aria-label="Saved views">
            <.saved_view
              navigate={~p"/inventory/resources?stale=true"}
              label="Needs attention"
              tone="critical"
            />
            <.saved_view
              navigate={~p"/inventory/resources?stale=true"}
              label="Stale inventory"
              tone="warning"
            />
            <.saved_view
              navigate={~p"/inventory/operations?disconnected=true"}
              label="Disconnected agents"
              tone="neutral"
            />
          </nav>
        </div>

        <div class="mt-auto border-t border-base-content/10 pt-3">
          <div class="flex items-center gap-1 px-1">
            <.link
              navigate={~p"/users/settings"}
              class="flex min-w-0 flex-1 items-center gap-2 rounded-md px-1.5 py-1.5 transition hover:bg-base-content/[0.05]"
            >
              <span class="grid size-7 shrink-0 place-items-center rounded-full border border-base-content/15 bg-base-100 text-[11px] font-semibold uppercase">
                {String.first(@current_scope.user.email)}
              </span>
              <span class="min-w-0 truncate text-xs">{@current_scope.user.email}</span>
            </.link>
            <.theme_toggle />
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-md p-2 text-base-content/45 transition hover:bg-base-content/[0.05] hover:text-base-content"
              aria-label="Log out"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>

      <main id="app-content" class="min-w-0 flex-1 overflow-x-hidden bg-base-100">
        <div class={@content_class}>{render_slot(@inner_block)}</div>
      </main>
    </div>

    <div :if={is_nil(@current_scope) || is_nil(@current_scope.organization_id)}>
      <header class="border-b border-base-content/10 bg-base-100">
        <div class="mx-auto flex min-h-16 max-w-screen-xl items-center px-4 sm:px-6 lg:px-8">
          <.link
            navigate={if(@current_scope, do: ~p"/organizations", else: ~p"/")}
            class="flex items-center gap-2.5 font-semibold tracking-tight"
          >
            <span class="text-orange-600">
              <.icon name="hero-server-stack-solid" class="size-6" />
            </span>
            <span>Renga</span>
          </.link>
          <div class="ml-auto flex items-center gap-1">
            <.theme_toggle />
            <.link
              :if={@current_scope && @current_scope.user}
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-md p-2 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
              aria-label="Log out"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </header>

      <main class="min-h-[calc(100vh-4rem)] bg-base-200/45 px-4 py-8 sm:px-6 lg:px-8 lg:py-10">
        <div class="mx-auto max-w-screen-xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active?, :boolean, required: true

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active? && "page"}
      class={[
        "relative flex h-9 items-center gap-2.5 rounded-md px-2.5 text-xs transition",
        @active? && "bg-base-content/[0.07] font-medium text-base-content",
        !@active? && "text-base-content/60 hover:bg-base-content/[0.04] hover:text-base-content"
      ]}
    >
      <span :if={@active?} class="absolute inset-y-2 -left-3 w-0.5 rounded-r bg-orange-600" />
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, required: true

  defp saved_view(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex h-8 items-center gap-2.5 rounded-md px-2.5 text-xs text-base-content/55 transition hover:bg-base-content/[0.04] hover:text-base-content"
    >
      <span class={[
        "size-2 rounded-full border",
        @tone == "critical" && "border-rose-500",
        @tone == "warning" && "border-amber-500",
        @tone == "neutral" && "border-base-content/45"
      ]} />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="rounded-md p-2 text-base-content/45 transition hover:bg-base-content/[0.05] hover:text-base-content"
      phx-click={JS.dispatch("phx:toggle-theme")}
      aria-label="Toggle color theme"
    >
      <.icon name="hero-moon" class="hidden size-4 [[data-theme=light]_&]:block" />
      <.icon name="hero-sun" class="hidden size-4 [[data-theme=dark]_&]:block" />
      <.icon
        name="hero-computer-desktop"
        class="size-4 [[data-theme=light]_&]:hidden [[data-theme=dark]_&]:hidden"
      />
    </button>
    """
  end
end
