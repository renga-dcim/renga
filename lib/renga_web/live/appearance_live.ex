defmodule RengaWeb.AppearanceLive do
  @moduledoc """
  Appearance settings (RFD 8, "Visual design"): each person's theme,
  accent, and density, saved to their account so they follow them across
  devices, and, for owners, the accent the organization's members see
  until they choose their own.

  Choices apply as soon as they are made: the page saves them and pushes
  the new appearance to the browser (`RengaWeb.AppearanceHook`).
  """
  use RengaWeb, :live_view

  alias Renga.Accounts
  alias Renga.Accounts.Appearance
  alias RengaWeb.AppearanceHook

  # The light-theme accent colors from assets/css/tokens.css, so each swatch
  # shows its own accent rather than the one currently applied.
  @swatches %{
    "copper" => "#b4531c",
    "petrol" => "#0b6e7f",
    "cobalt" => "#2f5bea",
    "iris" => "#5b5bd6",
    "mono" => "#111111"
  }

  @themes [
    {"system", "Match system", "hero-computer-desktop"},
    {"light", "Light", "hero-sun"},
    {"dark", "Dark", "hero-moon"}
  ]

  @densities [
    {"comfortable", "Comfortable", "Roomier rows; the default"},
    {"compact", "Compact", "More rows on screen"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Appearance",
       themes: @themes,
       densities: @densities,
       accents: Appearance.accents(),
       swatches: @swatches,
       saved?: false
     )
     |> assign_appearance()}
  end

  @impl true
  def handle_event("save", %{"appearance" => params}, socket) do
    %{current_scope: scope} = socket.assigns

    case Accounts.update_user_appearance(scope.user, Map.take(params, ~w(theme accent density))) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | user: user})
         |> assign(:saved?, true)
         |> assign_appearance()
         |> AppearanceHook.push_appearance()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That appearance could not be saved")}
    end
  end

  def handle_event(
        "save_default_accent",
        %{"organization" => %{"default_accent" => accent}},
        socket
      ) do
    %{current_scope: scope} = socket.assigns

    case Accounts.set_default_accent(scope, accent) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | organization: organization})
         |> put_flash(
           :info,
           "Members without their own accent now see #{Appearance.accent_label(accent)}"
         )
         |> assign_appearance()
         |> AppearanceHook.push_appearance()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners change the organization's default")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That accent could not be saved")}
    end
  end

  defp assign_appearance(socket) do
    %{current_scope: scope} = socket.assigns
    user = scope.user

    organization_accent =
      (scope.organization && scope.organization.default_accent) || Appearance.default_accent()

    assign(socket,
      theme: user.theme,
      accent: user.accent || "",
      density: user.density,
      organization_accent: organization_accent,
      owner?: not is_nil(scope.organization) and "owner" in (scope.roles || [])
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:appearance}
    >
      <div id="appearance" class="mx-auto max-w-2xl space-y-8 px-4 py-6 sm:px-6 lg:px-8">
        <header class="space-y-1">
          <h1 class="text-xl font-semibold tracking-tight text-fg">Appearance</h1>
          <p class="text-sm text-fg-muted">
            Saved to your account, so it follows you to every device.
            <span id="appearance-saved" aria-live="polite" class="text-fg">
              {if @saved?, do: "Saved."}
            </span>
          </p>
        </header>

        <.form for={%{}} as={:appearance} id="appearance-form" phx-change="save" class="space-y-8">
          <fieldset class="space-y-2">
            <legend class="text-sm font-medium text-fg">Theme</legend>
            <div class="grid grid-cols-3 gap-2">
              <label
                :for={{value, label, icon} <- @themes}
                class={choice_class(@theme == value)}
              >
                <input
                  type="radio"
                  name="appearance[theme]"
                  id={"theme-#{value}"}
                  value={value}
                  checked={@theme == value}
                  class="sr-only"
                />
                <.icon name={icon} class="size-5" />
                <span class="text-sm">{label}</span>
              </label>
            </div>
          </fieldset>

          <fieldset class="space-y-2">
            <legend class="text-sm font-medium text-fg">Accent</legend>
            <p class="text-xs text-fg-muted">
              Status colors stay the same whatever the accent, so a warning never looks like a link.
            </p>
            <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
              <label class={choice_class(@accent == "", :row)}>
                <input
                  type="radio"
                  name="appearance[accent]"
                  id="accent-default"
                  value=""
                  checked={@accent == ""}
                  class="sr-only"
                />
                <.swatch color={@swatches[@organization_accent]} />
                <span class="min-w-0 text-sm">
                  <span class="block">Organization default</span>
                  <span class="block text-xs text-fg-muted">
                    {Appearance.accent_label(@organization_accent)}
                  </span>
                </span>
              </label>
              <label :for={accent <- @accents} class={choice_class(@accent == accent, :row)}>
                <input
                  type="radio"
                  name="appearance[accent]"
                  id={"accent-#{accent}"}
                  value={accent}
                  checked={@accent == accent}
                  class="sr-only"
                />
                <.swatch color={@swatches[accent]} />
                <span class="text-sm">{Appearance.accent_label(accent)}</span>
              </label>
            </div>
          </fieldset>

          <fieldset class="space-y-2">
            <legend class="text-sm font-medium text-fg">Density</legend>
            <p class="text-xs text-fg-muted">
              Touch screens keep 44px targets at either density.
            </p>
            <div class="grid gap-2 sm:grid-cols-2">
              <label
                :for={{value, label, hint} <- @densities}
                class={choice_class(@density == value, :row)}
              >
                <input
                  type="radio"
                  name="appearance[density]"
                  id={"density-#{value}"}
                  value={value}
                  checked={@density == value}
                  class="sr-only"
                />
                <span class={[
                  "grid w-10 shrink-0 rounded border border-edge bg-surface p-1",
                  if(value == "compact", do: "gap-0.5", else: "gap-1")
                ]}>
                  <span
                    :for={_ <- 1..3}
                    class={["rounded-sm bg-edge", if(value == "compact", do: "h-1", else: "h-1.5")]}
                  />
                </span>
                <span class="min-w-0 text-sm">
                  <span class="block">{label}</span>
                  <span class="block text-xs text-fg-muted">{hint}</span>
                </span>
              </label>
            </div>
          </fieldset>
        </.form>

        <section
          :if={@owner?}
          id="organization-appearance"
          aria-labelledby="organization-appearance-title"
          class="space-y-2 border-t border-edge pt-6"
        >
          <h2 id="organization-appearance-title" class="text-sm font-medium text-fg">
            Organization default accent
          </h2>
          <p class="text-xs text-fg-muted">
            What members of {@current_scope.organization.name} see until they choose their own.
          </p>
          <.form
            for={%{}}
            as={:organization}
            id="default-accent-form"
            phx-change="save_default_accent"
            class="grid grid-cols-2 gap-2 sm:grid-cols-3"
          >
            <label
              :for={accent <- @accents}
              class={choice_class(@organization_accent == accent, :row)}
            >
              <input
                type="radio"
                name="organization[default_accent]"
                id={"default-accent-#{accent}"}
                value={accent}
                checked={@organization_accent == accent}
                class="sr-only"
              />
              <.swatch color={@swatches[accent]} />
              <span class="text-sm">{Appearance.accent_label(accent)}</span>
            </label>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :color, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <span
      class="size-5 shrink-0 rounded-full ring-1 ring-edge ring-offset-1 ring-offset-surface"
      style={"background-color: #{@color}"}
      aria-hidden="true"
    />
    """
  end

  # A radio choice drawn as a card; the checked one is outlined in the
  # accent, and the focus ring follows the keyboard into the group.
  defp choice_class(checked?, layout \\ :stack) do
    [
      "flex min-h-tap cursor-pointer gap-2 rounded-lg border px-3 py-2 transition-colors",
      "has-[:focus-visible]:ring-4 has-[:focus-visible]:ring-ring",
      if(layout == :stack, do: "flex-col items-center justify-center", else: "items-center"),
      if(checked?,
        do: "border-accent bg-accent-tint text-fg",
        else: "border-edge bg-surface text-fg-muted hover:bg-sunken hover:text-fg"
      )
    ]
  end
end
