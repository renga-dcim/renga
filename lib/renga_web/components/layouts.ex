defmodule RengaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RengaWeb, :html

  alias RengaWeb.Navigation

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
    doc: """
    the page's section id in `RengaWeb.Navigation`, such as `:vlans`; its area
    is highlighted and the area's tabs are shown. Unknown ids raise.
    """

  attr :content_class, :string, default: "p-6", doc: "classes for the authenticated workspace"

  attr :sidebar_views, :list,
    default: [],
    doc: "the person's pinned saved views, from `RengaWeb.SidebarViews`"

  attr :commands, :list,
    default: [],
    doc: """
    actions on the page's object, listed first in the command menu. Each is a
    map with `:id`, `:label`, `:icon`, and either `:run` (a `Phoenix.LiveView.JS`
    command or event name) or `:unavailable`, a sentence saying why it cannot
    run right now. RFD 8 asks the menu to explain unavailable actions rather
    than hide them, so people learn what is possible and what is blocking it.
    """

  attr :command_context, :string,
    default: nil,
    doc: "the object the commands act on, such as a resource name"

  slot :inner_block, required: true

  def app(assigns) do
    {area, section} = Navigation.locate(assigns.active_nav)

    assigns =
      assign(assigns,
        area: area,
        section: section,
        areas: Navigation.areas(),
        settings: Navigation.settings(),
        views: Enum.map(assigns.sidebar_views, &Navigation.view_link/1)
      )

    ~H"""
    <div :if={@current_scope && @current_scope.organization_id} class="flex min-h-screen bg-canvas">
      <aside
        id="app-sidebar"
        class="sticky top-0 hidden h-screen w-56 shrink-0 flex-col overflow-y-auto border-r border-edge bg-sunken px-3 py-4 lg:flex"
      >
        <.brand />

        <.link
          id="organization-switcher"
          navigate={~p"/organizations"}
          class="mt-3 flex h-10 items-center gap-2 rounded-md border border-edge bg-surface px-2.5 text-xs font-medium text-fg transition hover:border-fg-subtle"
        >
          <.icon name="hero-cube" class="size-4 text-fg-muted" />
          <span class="min-w-0 flex-1 truncate">{@current_scope.organization.name}</span>
          <.icon name="hero-chevron-up-down" class="size-3.5 text-fg-subtle" />
        </.link>

        <button
          id="command-palette-trigger"
          type="button"
          class="mt-3 flex h-10 w-full cursor-pointer items-center gap-2 rounded-md border border-edge bg-surface px-2.5 text-left text-xs text-fg-muted transition hover:border-fg-subtle hover:text-fg"
          phx-click={JS.dispatch("renga:open-command-palette")}
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
          <span class="min-w-0 flex-1 truncate">Search</span>
          <kbd class="rounded border border-edge bg-sunken px-1.5 py-0.5 font-mono text-[10px] text-fg-subtle">
            Ctrl K
          </kbd>
        </button>

        <nav id="primary-navigation" class="mt-5 space-y-0.5" aria-label="Primary navigation">
          <.nav_link
            :for={area <- @areas}
            navigate={Navigation.path(area)}
            icon={area.icon}
            label={area.label}
            title={area.question}
            active?={@area && @area.id == area.id}
          />
        </nav>

        <.saved_views views={@views} class="mt-5 border-t border-edge pt-5" />

        <div class="mt-auto space-y-1 border-t border-edge pt-3">
          <.nav_link
            id="settings-link"
            navigate={Navigation.path(@settings)}
            icon={@settings.icon}
            label={@settings.label}
            active?={@area && @area.id == :settings}
          />
          <div class="flex items-center gap-1 px-1">
            <.link
              navigate={~p"/users/settings"}
              title={@current_scope.user.email}
              aria-label={"Account settings for #{@current_scope.user.email}"}
              class="flex min-w-0 flex-1 items-center gap-2 rounded-md px-1.5 py-1.5 transition hover:bg-surface"
            >
              <span class="grid size-7 shrink-0 place-items-center rounded-full border border-edge bg-surface text-[11px] font-semibold uppercase text-fg">
                {String.first(@current_scope.user.email)}
              </span>
              <%!-- The sidebar is 14rem wide, so a long email is truncated on purpose; the
              title and aria-label carry the full address without leaking anything else. --%>
              <span class="min-w-0 truncate text-xs text-fg-muted" title={@current_scope.user.email}>
                {@current_scope.user.email}
              </span>
            </.link>
            <.theme_toggle />
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-md p-2 text-fg-subtle transition hover:bg-surface hover:text-fg"
              aria-label="Log out"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>

      <main
        id="app-content"
        class="flex min-h-screen min-w-0 flex-1 flex-col overflow-x-hidden bg-canvas"
      >
        <header
          id="app-mobile-header"
          class="flex h-12 shrink-0 items-center gap-2 border-b border-edge bg-sunken px-3 lg:hidden"
        >
          <details id="app-mobile-navigation" class="group relative">
            <summary
              id="mobile-navigation-trigger"
              class="grid size-8 min-h-tap min-w-tap cursor-pointer list-none place-items-center rounded-md text-fg-muted transition hover:bg-surface hover:text-fg"
              aria-label="Open navigation"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </summary>
            <div class="absolute left-0 top-10 z-40 max-h-[80vh] w-64 overflow-y-auto rounded-lg border border-edge bg-surface p-2 shadow-xl">
              <p class="truncate px-2 py-2 text-[10px] font-medium text-fg-subtle">
                {@current_scope.organization.name}
              </p>
              <nav class="space-y-0.5" aria-label="Mobile navigation">
                <.nav_link
                  :for={area <- @areas}
                  navigate={Navigation.path(area)}
                  icon={area.icon}
                  label={area.label}
                  active?={@area && @area.id == area.id}
                />
              </nav>
              <.saved_views views={@views} class="mt-2 border-t border-edge pt-2" />
              <nav class="mt-2 space-y-0.5 border-t border-edge pt-2" aria-label="Settings">
                <.nav_link
                  :for={item <- @settings.sections}
                  navigate={item.path}
                  icon={item.icon}
                  label={item.label}
                  active?={@section && @section.id == item.id}
                />
              </nav>
            </div>
          </details>
          <.brand class="h-auto" />
          <div class="ml-auto flex items-center gap-1">
            <button
              type="button"
              phx-click={JS.dispatch("renga:open-command-palette")}
              class="rounded-md p-2 text-fg-subtle transition hover:bg-surface hover:text-fg"
              aria-label="Open command menu"
            >
              <.icon name="hero-magnifying-glass" class="size-4" />
            </button>
            <.theme_toggle />
          </div>
        </header>
        <div class={["min-h-0 flex-1", @content_class]}>
          <.area_tabs :if={@area && length(@area.sections) > 1} area={@area} section={@section} />
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.command_palette
      :if={@current_scope && @current_scope.organization_id}
      areas={@areas}
      settings={@settings}
      views={@views}
      commands={@commands}
      command_context={@command_context}
    />

    <div :if={is_nil(@current_scope) || is_nil(@current_scope.organization_id)}>
      <header class="border-b border-edge bg-canvas">
        <div class="mx-auto flex min-h-16 max-w-screen-xl items-center px-4 sm:px-6 lg:px-8">
          <.link
            navigate={if(@current_scope, do: ~p"/organizations", else: ~p"/")}
            class="flex items-center gap-2.5 font-semibold tracking-tight text-fg"
          >
            <span class="text-accent"><.icon name="hero-server-stack-solid" class="size-6" /></span>
            <span>Renga</span>
          </.link>
          <div class="ml-auto flex items-center gap-1">
            <.theme_toggle />
            <.link
              :if={@current_scope && @current_scope.user}
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-md p-2 text-fg-subtle transition hover:bg-sunken hover:text-fg"
              aria-label="Log out"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </header>

      <main class="min-h-[calc(100vh-4rem)] bg-sunken px-4 py-8 sm:px-6 lg:px-8 lg:py-10">
        <div class="mx-auto max-w-screen-xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :class, :string, default: "h-10"

  defp brand(assigns) do
    ~H"""
    <.link
      navigate={~p"/inbox"}
      class={["flex items-center gap-2.5 px-2 text-sm font-semibold tracking-tight text-fg", @class]}
      aria-label="Renga home"
    >
      <.icon name="hero-server-stack-solid" class="size-6 text-accent" />
      <span class="text-base">Renga</span>
    </.link>
    """
  end

  # Tabs for the sections of the current area, such as Network's Topology,
  # VLANs, VLAN groups, and Cables. Generated here so every area's tabs look
  # and behave the same and pages do not each build their own.
  attr :area, :map, required: true
  attr :section, :map, required: true

  defp area_tabs(assigns) do
    ~H"""
    <nav
      id="area-tabs"
      aria-label={"#{@area.label} sections"}
      class="-mt-2 mb-6 flex gap-1 overflow-x-auto border-b border-edge"
    >
      <.link
        :for={item <- @area.sections}
        navigate={item.path}
        aria-current={item.id == @section.id && "page"}
        class={[
          "-mb-px flex min-h-tap shrink-0 items-center border-b-2 px-3 py-2 text-sm transition-colors",
          item.id == @section.id && "border-accent font-medium text-fg",
          item.id != @section.id && "border-transparent text-fg-muted hover:text-fg"
        ]}
      >
        {item.label}
      </.link>
    </nav>
    """
  end

  attr :views, :list, required: true
  attr :class, :string, default: nil

  defp saved_views(assigns) do
    ~H"""
    <div :if={@views != []} class={@class}>
      <p class="px-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-subtle">Views</p>
      <nav class="mt-2 space-y-0.5" aria-label="Saved views">
        <.link
          :for={view <- @views}
          navigate={view.path}
          data-view-id={view.id}
          class="flex h-8 min-h-tap items-center gap-2.5 rounded-md px-2.5 text-xs text-fg-muted transition hover:bg-surface hover:text-fg"
        >
          <.icon
            name={if(view.shared?, do: "hero-rectangle-stack-mini", else: "hero-user-mini")}
            class="size-3.5 shrink-0 text-fg-subtle"
          />
          <span class="truncate">{view.label}</span>
          <span class="sr-only">
            {if(view.shared?, do: "(organization view)", else: "(your view)")}
          </span>
        </.link>
      </nav>
    </div>
    """
  end

  attr :areas, :list, required: true
  attr :settings, :map, required: true
  attr :views, :list, required: true
  attr :commands, :list, required: true
  attr :command_context, :string, required: true

  # The menu stays server-rendered so page actions update while it is open:
  # the dialog keeps its client-side `open` state, the query input is left
  # alone, and the CommandPalette hook re-applies the filter after each patch.
  defp command_palette(assigns) do
    ~H"""
    <div id="command-palette-root" phx-hook="CommandPalette">
      <dialog
        id="command-palette"
        phx-mounted={JS.ignore_attributes("open")}
        class="m-auto w-[min(42rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-edge bg-surface p-0 text-fg shadow-2xl backdrop:bg-black/60"
        aria-label="Command menu"
      >
        <div id="command-palette-query" phx-update="ignore" class="border-b border-edge p-3">
          <div class="relative [&_.field]:!mb-0">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-2.5 z-10 size-4 text-fg-subtle"
            />
            <.input
              id="command-palette-input"
              name="command_search"
              type="search"
              value=""
              placeholder="Type a command or search resources..."
              autocomplete="off"
              class="h-9 w-full rounded-md border border-edge bg-canvas py-0 pl-9 pr-12 text-xs text-fg outline-none placeholder:text-fg-subtle focus:border-accent"
            />
            <kbd class="pointer-events-none absolute right-2.5 top-2 rounded border border-edge bg-sunken px-1.5 py-0.5 font-mono text-[10px] text-fg-subtle">
              Esc
            </kbd>
          </div>
        </div>

        <div class="max-h-[28rem] overflow-y-auto p-2">
          <div id="command-resource-search" data-command-item data-search="" hidden>
            <.command_group label="Search" />
            <a
              href={~p"/inventory"}
              class="flex h-11 items-center gap-3 rounded-md px-2.5 text-xs outline-none transition hover:bg-sunken focus:bg-sunken"
            >
              <.icon name="hero-magnifying-glass" class="size-4 text-fg-subtle" />
              <span>Search resources</span>
              <span class="ml-auto font-mono text-[10px] text-fg-subtle">Enter</span>
            </a>
          </div>

          <div :if={@commands != []} id="command-actions">
            <.command_group label={
              if(@command_context, do: "Actions on #{@command_context}", else: "Actions")
            } />
            <.command_action :for={command <- @commands} command={command} />
          </div>

          <.command_group label="Go to" />
          <%= for area <- @areas, item <- area.sections do %>
            <.command_link
              navigate={item.path}
              icon={item.icon}
              label={item.label}
              context={length(area.sections) > 1 && area.label}
              keywords={[area.label | item.keywords]}
            />
          <% end %>

          <div :if={@views != []}>
            <.command_group label="Views" />
            <.command_link
              :for={view <- @views}
              navigate={view.path}
              icon="hero-funnel"
              label={view.label}
              keywords={["view"]}
            />
          </div>

          <.command_group label={@settings.label} />
          <.command_link
            :for={item <- @settings.sections}
            navigate={item.path}
            icon={item.icon}
            label={item.label}
            keywords={[@settings.label | item.keywords]}
          />

          <.command_group label="Actions" />
          <button
            type="button"
            data-command-item
            data-search="switch theme light dark"
            data-command-action="toggle-theme"
            class="flex h-10 w-full items-center gap-3 rounded-md px-2.5 text-left text-xs text-fg-muted outline-none transition hover:bg-sunken focus:bg-sunken focus:text-fg"
          >
            <.icon name="hero-moon" class="size-4 text-fg-subtle" />
            <span>Switch theme</span>
          </button>
        </div>

        <footer class="flex h-9 items-center gap-4 border-t border-edge px-4 text-[10px] text-fg-subtle">
          <span><kbd class="font-mono">↑↓</kbd> Navigate</span>
          <span><kbd class="font-mono">Enter</kbd> Open</span>
          <span><kbd class="font-mono">Esc</kbd> Close</span>
        </footer>
      </dialog>
    </div>
    """
  end

  attr :command, :map, required: true

  defp command_action(%{command: %{unavailable: reason}} = assigns) when is_binary(reason) do
    ~H"""
    <button
      id={"command-#{@command.id}"}
      type="button"
      data-command-item
      data-search={String.downcase("#{@command.label} #{@command.unavailable}")}
      aria-disabled="true"
      aria-describedby={"command-#{@command.id}-reason"}
      class="flex min-h-10 w-full cursor-not-allowed items-center gap-3 rounded-md px-2.5 py-2 text-left text-xs outline-none focus:bg-sunken"
    >
      <.icon name={@command.icon} class="size-4 shrink-0 text-fg-subtle" />
      <span class="text-fg-muted">{@command.label}</span>
      <span id={"command-#{@command.id}-reason"} class="ml-auto text-right text-fg-subtle">
        {@command.unavailable}
      </span>
    </button>
    """
  end

  defp command_action(assigns) do
    ~H"""
    <button
      id={"command-#{@command.id}"}
      type="button"
      data-command-item
      data-search={String.downcase(@command.label)}
      phx-click={@command.run}
      class="flex h-10 w-full items-center gap-3 rounded-md px-2.5 text-left text-xs text-fg outline-none transition hover:bg-sunken focus:bg-sunken"
    >
      <.icon name={@command.icon} class="size-4 shrink-0 text-fg-subtle" />
      <span>{@command.label}</span>
    </button>
    """
  end

  attr :label, :string, required: true

  defp command_group(assigns) do
    ~H"""
    <p class="px-2 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle">
      {@label}
    </p>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :context, :any, default: nil, doc: "the area name, shown when the label alone is ambiguous"
  attr :keywords, :list, default: []

  defp command_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      data-command-item
      data-search={
        [@label, @context | @keywords] |> Enum.filter(& &1) |> Enum.join(" ") |> String.downcase()
      }
      class="flex h-10 items-center gap-3 rounded-md px-2.5 text-xs text-fg-muted outline-none transition hover:bg-sunken focus:bg-sunken focus:text-fg"
    >
      <.icon name={@icon} class="size-4 text-fg-subtle" />
      <span class="text-fg">{@label}</span>
      <span :if={@context} class="text-fg-subtle">{@context}</span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :active?, :boolean, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      title={@title}
      aria-current={@active? && "page"}
      class={[
        "relative flex h-9 min-h-tap items-center gap-2.5 rounded-md px-2.5 text-xs transition-colors",
        @active? && "bg-nav-active font-medium text-fg",
        !@active? && "text-fg-muted hover:bg-surface hover:text-fg"
      ]}
    >
      <span :if={@active?} class="absolute inset-y-2 -left-3 w-0.5 rounded-r bg-accent" />
      <.icon name={@icon} class="size-4" />
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
      class="rounded-md p-2 text-fg-subtle transition hover:bg-surface hover:text-fg"
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
