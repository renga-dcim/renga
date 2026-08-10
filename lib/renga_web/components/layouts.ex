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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 border-b border-base-content/10 bg-base-100/90 backdrop-blur-xl">
      <div class="mx-auto flex min-h-16 max-w-screen-2xl items-center gap-6 px-4 sm:px-6 lg:px-8">
        <.link
          navigate={
            if(@current_scope && @current_scope.organization_id,
              do: ~p"/inventory",
              else: ~p"/organizations"
            )
          }
          class="flex items-center gap-3 font-semibold tracking-tight"
        >
          <span class="grid size-9 place-items-center rounded-xl bg-orange-500 text-white shadow-sm shadow-orange-500/20">
            <.icon name="hero-server-stack-solid" class="size-5" />
          </span>
          <span>Renga</span>
        </.link>

        <nav :if={@current_scope && @current_scope.organization_id} class="flex items-center gap-1">
          <.link
            navigate={~p"/inventory"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            Overview
          </.link>
          <.link
            navigate={~p"/inventory/resources"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            Resources
          </.link>
          <.link
            navigate={~p"/inventory/operations"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            Collectors
          </.link>
          <.link
            navigate={~p"/inventory/enrollment"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            Enrollment
          </.link>
          <.link
            navigate={~p"/organizations"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
          >
            Switch organization
          </.link>
        </nav>

        <div class="ml-auto flex items-center gap-3">
          <div :if={@current_scope && @current_scope.organization} class="hidden text-right sm:block">
            <p class="text-sm font-medium">{@current_scope.organization.name}</p>
            <p class="text-xs text-base-content/50">Operational inventory</p>
          </div>
          <.theme_toggle />
          <.link
            :if={@current_scope && @current_scope.user}
            href={~p"/users/log-out"}
            method="delete"
            class="rounded-lg p-2 text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
          </.link>
        </div>
      </div>
    </header>

    <main class="min-h-[calc(100vh-4rem)] bg-gradient-to-b from-base-200/60 to-base-100 px-4 py-8 sm:px-6 lg:px-8 lg:py-10">
      <div class="mx-auto max-w-screen-2xl space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
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
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
