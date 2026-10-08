defmodule RengaWeb.UI do
  @moduledoc """
  Shared building blocks for RFD 8's product experience.

  Every screen composes these instead of hand-rolling markup, so the status
  vocabulary, object layout, properties, and overlays look and behave the same
  across domains. Styling uses only the design tokens (see
  `assets/css/tokens.css`), so accent, theme, and density apply automatically.

  Lists use `RengaWeb.CoreComponents.table/1`.
  """
  use Phoenix.Component
  use Gettext, backend: RengaWeb.Gettext

  import RengaWeb.CoreComponents, only: [icon: 1, button: 1]

  alias Phoenix.LiveView.JS

  ## Status strip

  @doc """
  Renders the four independent status signals in their fixed order:
  lifecycle, freshness, agent connectivity, and drift.

  RFD 1 keeps these signals independent, so the strip never merges them into
  one status. Each signal pairs a shape with its color so it stays readable
  in grayscale, and carries a text label for assistive technology.

  ## Examples

      <.status_strip
        lifecycle="active"
        freshness={:current}
        freshness_label="1m"
        agent={:connected}
        drift={1}
      />
  """
  attr :id, :string, default: nil
  attr :lifecycle, :string, default: nil, doc: "active, planned, inactive, retired, or nil"
  attr :freshness, :atom, default: :unknown, values: [:current, :stale, :unknown]
  attr :freshness_label, :string, default: nil, doc: "age such as \"1m\"; defaults to the state"
  attr :agent, :atom, default: :none, values: [:connected, :lost, :none]
  attr :agent_label, :string, default: nil, doc: "overrides the default agent wording"
  attr :drift, :integer, default: 0, doc: "number of open drift findings"
  attr :size, :string, default: "row", values: ~w(row header)
  attr :class, :any, default: nil

  def status_strip(assigns) do
    assigns =
      assigns
      |> assign(:lifecycle_label, lifecycle_label(assigns.lifecycle))
      |> assign(:freshness_text, assigns.freshness_label || freshness_text(assigns.freshness))
      |> assign(:agent_text, assigns.agent_label || agent_text(assigns.agent))

    ~H"""
    <div
      id={@id}
      role="group"
      aria-label={gettext("Status")}
      class={[
        "flex flex-wrap items-center",
        @size == "row" && "gap-3 text-xs text-fg-muted",
        @size == "header" && "gap-1.5 text-xs text-fg",
        @class
      ]}
    >
      <span data-signal="lifecycle" class={signal_class(@size)}>
        <span class={lifecycle_mark(@lifecycle)} aria-hidden="true" />
        <span class="sr-only">{gettext("Lifecycle")}:</span>
        {@lifecycle_label}
      </span>
      <span data-signal="freshness" class={signal_class(@size)}>
        <.icon name="hero-clock-mini" class={"size-3.5 #{freshness_color(@freshness)}"} />
        <span class="sr-only">{gettext("Inventory")}:</span>
        <span class={@freshness == :stale && "font-medium text-warn-text"}>{@freshness_text}</span>
      </span>
      <span data-signal="agent" class={signal_class(@size)}>
        <span class={agent_mark(@agent)} aria-hidden="true" />
        <span class="sr-only">{gettext("Agent")}:</span>
        {@agent_text}
      </span>
      <span
        :if={@drift > 0}
        data-signal="drift"
        class="inline-flex items-center rounded border border-warn-line bg-warn-fill px-1.5 font-mono text-[11px] text-warn-text"
      >
        <span aria-hidden="true">≠ {@drift}</span>
        <span class="sr-only">{ngettext("1 drift finding", "%{count} drift findings", @drift)}</span>
      </span>
    </div>
    """
  end

  defp signal_class("row"), do: "inline-flex items-center gap-1.5"

  defp signal_class("header"),
    do: "inline-flex h-6 items-center gap-1.5 rounded-full border border-edge bg-surface px-2.5"

  defp lifecycle_label(nil), do: gettext("Unknown")
  defp lifecycle_label(state), do: state |> to_string() |> String.capitalize()

  @dot "inline-block size-2 shrink-0 rounded-full"

  defp lifecycle_mark("active"), do: [@dot, "bg-ok"]
  defp lifecycle_mark("planned"), do: [@dot, "border-[1.5px] border-info"]
  defp lifecycle_mark(state) when state in ["inactive", "retired"], do: [@dot, "bg-unknown"]
  defp lifecycle_mark(_unknown), do: [@dot, "border-[1.5px] border-unknown"]

  defp freshness_text(:current), do: gettext("Current")
  defp freshness_text(:stale), do: gettext("Stale")
  defp freshness_text(:unknown), do: gettext("Unknown")

  defp freshness_color(:current), do: "text-ok"
  defp freshness_color(:stale), do: "text-warn"
  defp freshness_color(:unknown), do: "text-unknown"

  defp agent_text(:connected), do: gettext("Agent")
  defp agent_text(:lost), do: gettext("Agent lost")
  defp agent_text(:none), do: gettext("No agent")

  defp agent_mark(:connected), do: [@dot, "bg-ok"]
  defp agent_mark(:lost), do: [@dot, "border-[1.5px] border-crit"]
  defp agent_mark(:none), do: [@dot, "border-[1.5px] border-unknown"]

  ## Object page

  @doc """
  Renders the shared object page layout: breadcrumb bar, title with status,
  domain tabs, main content, and a properties aside.

  Domains add tabs rather than pages (RFD 8, "Object pages"). Tabs are
  navigation links, so the active one carries `aria-current="page"`.

  ## Examples

      <.object_page id="resource" title="Primary compute node" subtitle="compute-01 · server">
        <:breadcrumb><.link navigate={~p"/inventory"}>Inventory</.link></:breadcrumb>
        <:status><.status_strip size="header" lifecycle="active" /></:status>
        <:tab patch={~p"/inventory/1"} active>Overview</:tab>
        <:tab patch={~p"/inventory/1/hardware"} count={2}>Hardware</:tab>
        Overview content
        <:aside><.properties>...</.properties></:aside>
      </.object_page>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  slot :breadcrumb
  slot :icon
  slot :status
  slot :actions

  slot :tab do
    attr :navigate, :string
    attr :patch, :string
    attr :active, :boolean
    attr :count, :integer
  end

  slot :inner_block, required: true
  slot :aside

  def object_page(assigns) do
    ~H"""
    <article id={@id} class="flex min-h-full flex-col">
      <div
        :if={@breadcrumb != [] or @actions != []}
        class="flex min-h-11 flex-wrap items-center gap-2 border-b border-edge px-6 text-xs text-fg-muted"
      >
        <nav
          :if={@breadcrumb != []}
          aria-label={gettext("Breadcrumb")}
          class="flex items-center gap-2"
        >
          {render_slot(@breadcrumb)}
        </nav>
        <div :if={@actions != []} class="ml-auto flex items-center gap-1.5">
          {render_slot(@actions)}
        </div>
      </div>

      <div class="flex flex-1 flex-wrap">
        <div class="min-w-0 flex-[999_1_560px] space-y-5 px-6 py-6 lg:px-8">
          <header class="space-y-2.5">
            <div class="flex items-center gap-3">
              <span
                :if={@icon != []}
                class="grid size-9 shrink-0 place-items-center rounded-lg border border-edge bg-surface text-fg-muted"
              >
                {render_slot(@icon)}
              </span>
              <div class="min-w-0">
                <h1 class="text-xl font-semibold tracking-tight text-fg text-balance">{@title}</h1>
                <p :if={@subtitle} class="font-mono text-xs text-fg-muted">{@subtitle}</p>
              </div>
            </div>
            <div :if={@status != []}>{render_slot(@status)}</div>
          </header>

          <nav
            :if={@tab != []}
            id={"#{@id}-tabs"}
            aria-label={gettext("Sections")}
            class="flex flex-wrap gap-5 border-b border-edge"
          >
            <.link
              :for={tab <- @tab}
              navigate={tab[:navigate]}
              patch={tab[:patch]}
              aria-current={tab[:active] && "page"}
              class={[
                "-mb-px inline-flex items-center gap-1.5 border-b-2 pb-2.5 text-sm transition-colors",
                tab[:active] && "border-fg font-medium text-fg",
                !tab[:active] && "border-transparent text-fg-muted hover:text-fg"
              ]}
            >
              {render_slot(tab)}
              <span :if={tab[:count]} class="font-mono text-[11px] text-fg-muted">{tab[:count]}</span>
            </.link>
          </nav>

          <div>{render_slot(@inner_block)}</div>
        </div>

        <aside
          :if={@aside != []}
          aria-label={gettext("Details")}
          class="min-w-0 flex-[1_1_300px] space-y-6 border-l border-edge px-5 py-6"
        >
          {render_slot(@aside)}
        </aside>
      </div>
    </article>
    """
  end

  ## Properties panel

  @doc """
  Renders an editable label/value list for an object's properties.

  An item with `on_edit` renders as a button so the whole row is the edit
  target; `blank` shows the placeholder instead of the value so empty
  properties invite input ("Add end date") rather than showing a dash.

  ## Examples

      <.properties id="resource-properties">
        <:item label="Lifecycle" on_edit={JS.push("edit", value: %{field: "lifecycle"})}>
          Active
        </:item>
        <:item label="Warranty" blank placeholder="Add end date" />
      </.properties>
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil

  slot :item, required: true do
    attr :label, :string, required: true
    attr :on_edit, :any, doc: "a JS command or event name; makes the row editable"
    attr :blank, :boolean
    attr :placeholder, :string
  end

  def properties(assigns) do
    ~H"""
    <section id={@id} class="space-y-1.5">
      <h2 class="text-xs font-medium text-fg-muted">{@title || gettext("Properties")}</h2>
      <dl class="-mx-2">
        <div
          :for={item <- @item}
          class="grid min-h-8 grid-cols-[7rem_minmax(0,1fr)] items-center gap-2 px-2 text-sm"
        >
          <dt class="text-fg-muted">{item.label}</dt>
          <dd class="min-w-0">
            <button
              :if={item[:on_edit]}
              type="button"
              phx-click={item[:on_edit]}
              class={[
                "-mx-1.5 block w-[calc(100%+0.75rem)] cursor-pointer truncate rounded-md px-1.5 py-1 text-left",
                "transition-colors hover:bg-sunken focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring",
                item[:blank] && "text-fg-subtle"
              ]}
            >
              <span class="sr-only">{gettext("Edit %{property}:", property: item.label)}</span>
              {if item[:blank], do: item[:placeholder] || gettext("Not set"), else: render_slot(item)}
            </button>
            <span :if={!item[:on_edit]} class={["block truncate", item[:blank] && "text-fg-subtle"]}>
              {if item[:blank], do: item[:placeholder] || gettext("Not set"), else: render_slot(item)}
            </span>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  ## Overlays

  @doc """
  Renders a side panel that slides in from the right for creating and
  editing, replacing always-open forms (RFD 8, "Actions").

  Open it with `show_overlay/2` (or `show` when it should start open) and
  close it with `hide_overlay/2`. Escape, the close button, and clicking
  outside all run `on_cancel`. Focus stays inside the panel while it is open.

  ## Examples

      <.button phx-click={show_overlay("new-vlan")}>New VLAN</.button>
      <.side_panel id="new-vlan" title="New VLAN">
        <.form ...>...</.form>
        <:footer><.button variant="primary" form="vlan-form">Create VLAN</.button></:footer>
      </.side_panel>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true
  slot :footer

  def side_panel(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Overlay"
      phx-remove={hide_overlay(@id)}
      data-initial-show={to_string(@show)}
      data-show={overlay_show(@id)}
      data-hide={overlay_hide(@id)}
      data-cancel={@on_cancel}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-backdrop"} class="fixed inset-0 hidden bg-fg/25" aria-hidden="true" />
      <div class="fixed inset-y-0 right-0 flex w-full max-w-md">
        <.focus_wrap
          id={"#{@id}-container"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          aria-describedby={@description && "#{@id}-description"}
          class="hidden h-full w-full flex-col border-l border-edge bg-surface text-fg shadow-2xl"
        >
          <header class="flex items-start gap-3 border-b border-edge px-5 py-4">
            <div class="min-w-0 flex-1">
              <h2 id={"#{@id}-title"} class="text-base font-semibold">{@title}</h2>
              <p :if={@description} id={"#{@id}-description"} class="mt-0.5 text-sm text-fg-muted">
                {@description}
              </p>
            </div>
            <.close_button id={@id} />
          </header>
          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">{render_slot(@inner_block)}</div>
          <footer
            :if={@footer != []}
            class="flex items-center justify-end gap-2 border-t border-edge px-5 py-3"
          >
            {render_slot(@footer)}
          </footer>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  @doc """
  Renders a confirmation dialog for consequential actions.

  `on_confirm` is a JS command or an event name; the dialog closes after it
  runs. Danger dialogs use the danger button so destructive intent is never
  styled like a routine primary action.

  ## Examples

      <.button variant="danger" phx-click={show_overlay("revoke-key")}>Revoke</.button>
      <.confirm_dialog
        id="revoke-key"
        title="Revoke intake key?"
        confirm_label="Revoke key"
        on_confirm={JS.push("revoke", value: %{id: @key.id})}
      >
        Collectors using this key stop reporting immediately.
      </.confirm_dialog>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, default: nil
  attr :cancel_label, :string, default: nil
  attr :variant, :string, default: "danger", values: ~w(danger primary)
  attr :on_confirm, :any, required: true, doc: "a JS command or event name"
  attr :on_cancel, JS, default: %JS{}
  attr :show, :boolean, default: false
  slot :inner_block

  def confirm_dialog(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Overlay"
      phx-remove={hide_overlay(@id)}
      data-initial-show={to_string(@show)}
      data-show={overlay_show(@id)}
      data-hide={overlay_hide(@id)}
      data-cancel={@on_cancel}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-backdrop"} class="fixed inset-0 hidden bg-fg/25" aria-hidden="true" />
      <div class="fixed inset-0 grid place-items-center p-4">
        <.focus_wrap
          id={"#{@id}-container"}
          role="alertdialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          aria-describedby={"#{@id}-message"}
          class="hidden w-full max-w-sm flex-col rounded-xl border border-edge bg-surface p-5 text-fg shadow-2xl"
        >
          <h2 id={"#{@id}-title"} class="text-base font-semibold">{@title}</h2>
          <div id={"#{@id}-message"} class="mt-1.5 text-sm text-fg-muted">
            {render_slot(@inner_block)}
          </div>
          <div class="mt-5 flex justify-end gap-2">
            <.button
              id={"#{@id}-cancel"}
              phx-click={JS.dispatch("renga:overlay-cancel", to: "##{@id}")}
            >
              {@cancel_label || gettext("Cancel")}
            </.button>
            <.button
              id={"#{@id}-confirm"}
              variant={@variant}
              phx-click={confirm_command(@on_confirm, @id)}
            >
              {@confirm_label || gettext("Confirm")}
            </.button>
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true

  defp close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={JS.dispatch("renga:overlay-cancel", to: "##{@id}")}
      class="grid min-h-tap size-8 shrink-0 cursor-pointer place-items-center rounded-md text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
      aria-label={gettext("Close")}
    >
      <.icon name="hero-x-mark" class="size-4" />
    </button>
    """
  end

  defp confirm_command(event, id) when is_binary(event),
    do: event |> JS.push() |> hide_overlay(id)

  defp confirm_command(%JS{} = js, id), do: hide_overlay(js, id)

  @doc """
  Opens a `side_panel/1` or `confirm_dialog/1` by id.
  """
  def show_overlay(js \\ %JS{}, id) when is_binary(id) do
    JS.dispatch(js, "renga:overlay-open", to: "##{id}")
  end

  @doc """
  Closes a `side_panel/1` or `confirm_dialog/1` by id and restores focus.
  Closing an already closed overlay is a no-op.
  """
  def hide_overlay(js \\ %JS{}, id) when is_binary(id) do
    JS.dispatch(js, "renga:overlay-close", to: "##{id}")
  end

  defp overlay_show(id) do
    %JS{}
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-backdrop",
      time: 200,
      transition: {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      display: "flex",
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2 sm:translate-y-0",
         "opacity-100 translate-y-0"}
    )
    |> JS.focus_first(to: "##{id}-container")
  end

  defp overlay_hide(id) do
    %JS{}
    |> JS.hide(
      to: "##{id}-backdrop",
      time: 150,
      transition: {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-container",
      time: 150,
      transition: {"transition-all ease-in duration-150", "opacity-100", "opacity-0"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"}, time: 150)
  end
end
