defmodule RengaWeb.DesignSystemLive do
  @moduledoc """
  The living companion to `docs/design-system.md`: every token and shared
  component rendered by the real CSS and components, with switches for
  accent, theme, and density.

  The switches only preview: they live in the URL (so a preview can be
  shared) and are applied to `<html>` through the same `appearance` event
  the Appearance settings use, but nothing is saved to the account.

  Only development and test builds route here (see the router), so the
  page links with plain paths rather than `~p`, which would warn in
  production builds where the route does not exist.
  """
  use RengaWeb, :live_view

  alias Renga.Accounts.Appearance

  @path "/dev/design-system"

  # Class names are written out in full so Tailwind generates them.
  @surfaces [
    {"canvas", "bg-canvas", "Page background"},
    {"surface", "bg-surface", "Cards, panels, tables, inputs"},
    {"sunken", "bg-sunken", "Sidebar, hover, wells"},
    {"nav-active", "bg-nav-active", "Current sidebar item"},
    {"edge", "bg-edge", "Borders of surfaces and controls"},
    {"line", "bg-line", "Rules between rows"},
    {"fg", "bg-fg", "Primary text"},
    {"fg-muted", "bg-fg-muted", "Secondary text, labels"},
    {"fg-subtle", "bg-fg-subtle", "Placeholders, empty values"}
  ]

  @accent [
    {"accent", "bg-accent", "Primary buttons, the key mark"},
    {"accent-hover", "bg-accent-hover", "Hover on accent fills"},
    {"accent-tint", "bg-accent-tint", "Selected rows"},
    {"link", "bg-link", "Inline links"},
    {"ring", "bg-ring", "Focus rings"}
  ]

  @status [
    {"ok", "bg-ok", "Healthy, active, connected"},
    {"warn", "bg-warn", "Stale, drift, attention"},
    {"warn-fill", "bg-warn-fill", "Warning banner fill"},
    {"crit", "bg-crit", "Failures, destructive"},
    {"crit-fill", "bg-crit-fill", "Critical banner fill"},
    {"info", "bg-info", "Planned, informational"},
    {"info-fill", "bg-info-fill", "Info banner fill"},
    {"unknown", "bg-unknown", "No evidence, retired"}
  ]

  @type_scale [
    {"text-xl font-semibold tracking-tight", "Page title", "Primary compute node"},
    {"text-lg font-semibold tracking-tight", "Header title", "Racks in Frankfurt"},
    {"text-base font-semibold", "Dialog and panel title", "Revoke intake key?"},
    {"text-sm", "Body, controls, properties", "Collectors using this key stop reporting."},
    {"text-table", "Table cells (follows density)", "compute-01 · 10.0.4.17"},
    {"text-xs text-fg-muted", "Labels, row metadata", "Last seen 2 minutes ago"},
    {"font-mono text-[11px] text-fg-muted", "Counts, inline badges", "12"},
    {"text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle", "Section overline",
     "Views"},
    {"font-mono text-sm", "Machine values", "00:1b:21:3a:4f:9c"}
  ]

  @radii [
    {"rounded-sm", "Small tags, rack blocks"},
    {"rounded", "Inside a control"},
    {"rounded-md", "Buttons, inputs"},
    {"rounded-lg", "Cards, menus"},
    {"rounded-xl", "Dialogs"},
    {"rounded-full", "Dots, pills"}
  ]

  @shadows [
    {"border border-edge", "Cards: border, no shadow"},
    {"shadow-sm", "Sign-in card"},
    {"shadow-lg", "Flashes, dropdowns"},
    {"shadow-xl", "Mobile menu"},
    {"shadow-2xl", "Dialogs, side panels"}
  ]

  @density [
    {"h-row", "--rg-row-h", "36px", "28px", "Table rows"},
    {"h-control", "--rg-control-h", "32px", "28px", "Buttons and inputs"},
    {"px-cell", "--rg-cell-px", "12px", "10px", "Table cell padding"},
    {"text-table", "--rg-table-text", "13px", "12px", "Table text"},
    {"rack-u", "--rg-rack-u", "16px", "12px", "One rack unit"},
    {"min-h-tap", "--rg-tap-min", "0", "0", "44px on touch screens"}
  ]

  @icons ~w(hero-server-stack-mini hero-cpu-chip-mini hero-signal-mini hero-map-pin-mini
            hero-inbox-mini hero-clock-mini hero-magnifying-glass-mini hero-plus-mini
            hero-pencil-square-mini hero-trash-mini hero-check-mini hero-x-mark-mini)

  @nodes [
    %{id: 1, group: "Frankfurt", name: "compute-01", kind: "Server", address: "10.0.4.17"},
    %{id: 2, group: "Frankfurt", name: "compute-02", kind: "Server", address: "10.0.4.18"},
    %{id: 3, group: "Frankfurt", name: "tor-a", kind: "Switch", address: "10.0.0.2"},
    %{id: 4, group: "Lisbon", name: "storage-01", kind: "Storage", address: "10.8.1.40"}
  ]

  @jobs [
    %{key: "inventory.collect@1", risk: "observe"},
    %{key: "query.disk_usage@1", risk: "observe"},
    %{key: "vm.power@1", risk: "operate"}
  ]

  @overflow_rows [
    %{
      id: 1,
      name: "Primary compute node",
      host: "compute-01",
      state: "Succeeded",
      dot: "bg-ok",
      detail: "Observation 7f3c91e2",
      jobs: Enum.take(@jobs, 1)
    },
    %{
      id: 2,
      name: "Billing analytics warehouse replica (us-east, cold standby)",
      host: "billing-dwh-replica-03",
      state: "Failed",
      dot: "bg-crit",
      detail: "Refused: inventory.collect is disabled in the agent's [jobs] policy on this host",
      jobs: @jobs
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Design system")
     |> assign(:current_scope, nil)
     |> assign(:surfaces, @surfaces)
     |> assign(:accent, @accent)
     |> assign(:status, @status)
     |> assign(:type_scale, @type_scale)
     |> assign(:radii, @radii)
     |> assign(:shadows, @shadows)
     |> assign(:density, @density)
     |> assign(:icons, @icons)
     |> assign(:selected_node, 1)
     |> assign(:overflow_rows, @overflow_rows)
     |> assign(:sample_form, sample_form())
     |> stream(:nodes, with_group_headers(@nodes))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    defaults = Map.from_struct(%Appearance{})

    preview = %{
      theme: pick(params["theme"], Appearance.themes(), defaults.theme),
      accent: pick(params["accent"], Appearance.accents(), defaults.accent),
      density: pick(params["density"], Appearance.densities(), defaults.density)
    }

    socket = assign(socket, :preview, preview)

    socket = if connected?(socket), do: push_event(socket, "appearance", preview), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("flash", %{"kind" => "info"}, socket) do
    {:noreply, put_flash(socket, :info, "Collector enrolled. It reports within a minute.")}
  end

  def handle_event("flash", %{"kind" => "error"}, socket) do
    {:noreply, put_flash(socket, :error, "The rack is full at that unit. Pick another position.")}
  end

  def handle_event("sample", %{"sample" => params}, socket) do
    {:noreply, assign(socket, :sample_form, to_form(params, as: :sample))}
  end

  def handle_event("confirm", _params, socket) do
    {:noreply, put_flash(socket, :info, "Confirmed.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} show_theme_toggle={false}>
      <div id="design-system" class="space-y-10">
        <.header>
          Design system
          <:subtitle>Tokens and shared components as the app renders them.</:subtitle>
        </.header>

        <div
          id="preview-controls"
          class="sticky top-0 z-20 -mx-4 flex flex-wrap items-center gap-x-6 gap-y-3 border-y border-edge bg-canvas/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-lg sm:border"
        >
          <.preview_switch
            id="preview-accent"
            label="Accent"
            key={:accent}
            options={for a <- Appearance.accents(), do: {a, Appearance.accent_label(a)}}
            preview={@preview}
          />
          <.preview_switch
            id="preview-theme"
            label="Theme"
            key={:theme}
            options={[{"light", "Light"}, {"dark", "Dark"}, {"system", "System"}]}
            preview={@preview}
          />
          <.preview_switch
            id="preview-density"
            label="Density"
            key={:density}
            options={[{"comfortable", "Comfortable"}, {"compact", "Compact"}]}
            preview={@preview}
          />
          <p class="text-xs text-fg-subtle sm:ml-auto">Preview only; nothing is saved.</p>
        </div>

        <.ds_section
          id="colors"
          title="Color"
          description="Token names, not palette colors. Each swatch is drawn from the live token, so switching accent or theme changes it."
        >
          <.swatches id="colors-surfaces" title="Surfaces and text" swatches={@surfaces} />
          <.swatches id="colors-accent" title="Accent" swatches={@accent} />
          <.swatches
            id="colors-status"
            title="Status (independent of accent)"
            swatches={@status}
          />
        </.ds_section>

        <.ds_section
          id="typography"
          title="Typography"
          description="System sans for everything; mono for identifiers, addresses, and counts."
        >
          <div class="divide-y divide-line rounded-lg border border-edge bg-surface">
            <div
              :for={{class, role, sample} <- @type_scale}
              class="grid gap-1 px-5 py-3 sm:grid-cols-[14rem_minmax(0,1fr)] sm:items-baseline sm:gap-6"
            >
              <div>
                <p class="text-sm text-fg">{role}</p>
                <p class="font-mono text-[11px] text-fg-subtle">{class}</p>
              </div>
              <p class={["min-w-0 truncate text-fg", class]}>{sample}</p>
            </div>
          </div>
        </.ds_section>

        <.ds_section
          id="density"
          title="Spacing and density"
          description="Density changes only these tokens. Shared components read them, so no screen handles density itself."
        >
          <div class="overflow-x-auto rounded-lg border border-edge bg-surface">
            <table class="w-full text-left text-sm">
              <thead class="text-xs text-fg-muted">
                <tr class="border-b border-edge">
                  <th class="px-4 py-2 font-medium">Class</th>
                  <th class="px-4 py-2 font-medium">Token</th>
                  <th class={density_heading(@preview, "comfortable")}>Comfortable</th>
                  <th class={density_heading(@preview, "compact")}>Compact</th>
                  <th class="px-4 py-2 font-medium">Used by</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{class, token, comfortable, compact, use} <- @density}
                  class="border-b border-line last:border-0"
                >
                  <td class="px-4 py-2 font-mono text-xs">{class}</td>
                  <td class="px-4 py-2 font-mono text-xs text-fg-muted">{token}</td>
                  <td class="px-4 py-2 font-mono text-xs">{comfortable}</td>
                  <td class="px-4 py-2 font-mono text-xs">{compact}</td>
                  <td class="px-4 py-2 text-xs text-fg-muted">{use}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.ds_section>

        <.ds_section
          id="shape"
          title="Shape and elevation"
          description="Surfaces separate with borders. Shadows are only for things that float."
        >
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            <div :for={{class, use} <- @radii} class="space-y-2">
              <div class={["h-16 border border-edge bg-surface", class]} />
              <p class="font-mono text-xs text-fg">{class}</p>
              <p class="text-xs text-fg-muted">{use}</p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <div :for={{class, use} <- @shadows} class="space-y-2">
              <div class={["h-16 rounded-lg bg-surface", class]} />
              <p class="font-mono text-xs text-fg">{class}</p>
              <p class="text-xs text-fg-muted">{use}</p>
            </div>
          </div>
        </.ds_section>

        <.ds_section
          id="status"
          title="Status"
          description="Every status pairs color with a shape or text, so it reads in grayscale."
        >
          <div class="space-y-3 rounded-lg border border-edge bg-surface p-5">
            <.status_strip
              id="status-healthy"
              lifecycle="active"
              freshness={:current}
              freshness_label="1m"
              agent={:connected}
            />
            <.status_strip
              id="status-attention"
              lifecycle="planned"
              freshness={:stale}
              freshness_label="3d"
              agent={:lost}
              drift={2}
            />
            <.status_strip id="status-unknown" lifecycle="retired" />
            <.status_strip
              id="status-header"
              size="header"
              lifecycle="active"
              freshness={:current}
              freshness_label="1m"
              agent={:connected}
              drift={1}
            />
          </div>
          <div class="grid gap-3 md:grid-cols-3">
            <p class="flex items-start gap-2 rounded-lg border border-warn-line bg-warn-fill p-3 text-sm text-warn-text">
              <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-4 shrink-0" />
              Memory reads 496 GB, expected 512 GB.
            </p>
            <p class="flex items-start gap-2 rounded-lg border border-crit-line bg-crit-fill p-3 text-sm text-fg">
              <.icon name="hero-x-circle-mini" class="mt-0.5 size-4 shrink-0 text-crit" />
              The agent has not checked in for 2 hours.
            </p>
            <p class="flex items-start gap-2 rounded-lg border border-edge bg-info-fill p-3 text-sm text-fg">
              <.icon
                name="hero-information-circle-mini"
                class="mt-0.5 size-4 shrink-0 text-info"
              /> This rack is planned and holds no devices yet.
            </p>
          </div>
        </.ds_section>

        <.ds_section
          id="components"
          title="Components"
          description="Compose these before writing markup. Each documents its attributes in its @doc."
        >
          <.ds_card id="component-buttons" title="Buttons">
            <div class="flex flex-wrap items-center gap-2">
              <.button variant="primary">Primary</.button>
              <.button>Secondary</.button>
              <.button variant="ghost">Ghost</.button>
              <.button variant="danger">Danger</.button>
              <.button disabled>Disabled</.button>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <.button size="sm" variant="primary">Small primary</.button>
              <.button size="sm">Small secondary</.button>
              <.button size="sm" variant="ghost">
                <.icon name="hero-plus-mini" class="size-4" />
                <span>With icon</span>
              </.button>
            </div>
          </.ds_card>

          <.ds_card id="component-inputs" title="Form fields">
            <.form
              for={@sample_form}
              id="sample-form"
              phx-change="sample"
              phx-submit="sample"
              class="grid gap-x-6 sm:grid-cols-2"
            >
              <.input field={@sample_form[:name]} label="Name" placeholder="compute-01" />
              <.input
                field={@sample_form[:site]}
                type="select"
                label="Site"
                prompt="Choose a site"
                options={[{"Frankfurt", "fra"}, {"Lisbon", "lis"}]}
              />
              <.input
                id="sample-serial"
                name="serial"
                value="SN-0042"
                label="Serial number"
                errors={["is already used by storage-01"]}
              />
              <.input field={@sample_form[:notes]} type="textarea" label="Notes" />
              <.input field={@sample_form[:monitored]} type="checkbox" label="Monitored" />
            </.form>
          </.ds_card>

          <.ds_card id="component-table" title="List">
            <.table
              id="sample-nodes"
              rows={@streams.nodes}
              row_group={fn {_id, row} -> row[:header] end}
              row_selected={fn {_id, row} -> row[:id] == @selected_node end}
            >
              <:col :let={{_id, node}} label="Name" class="font-medium">{node[:name]}</:col>
              <:col :let={{_id, node}} label="Kind">{node[:kind]}</:col>
              <:col :let={{_id, node}} label="Address" class="font-mono">{node[:address]}</:col>
              <:empty>No resources match these filters.</:empty>
            </.table>
          </.ds_card>

          <.ds_card id="component-overflow" title="Overflow">
            <p class="text-xs text-fg-muted">
              Rows stay on one line. Hover or focus a cut-off value to read it, open +N for
              the whole list, and narrow the window to watch Detail and Agent drop out.
            </p>
            <div class="w-48">
              <.clip id="sample-standalone-clip" class="text-xs text-fg-muted">
                Standalone values reveal their full text on focus or touch when space is tight.
              </.clip>
            </div>
            <.table
              id="sample-overflow"
              rows={@overflow_rows}
              overflow="clip"
              row_navigate={fn row -> ~p"/dev/design-system?overflow=#{row.id}" end}
            >
              <:col :let={row} label="Target">
                <span class="font-medium">{row.name}</span>
                <span class="font-mono text-xs text-fg-muted">{row.host}</span>
              </:col>
              <:col :let={row} label="State" class="w-32">
                <span class="inline-flex items-center gap-1.5">
                  <span class={["inline-block size-2 rounded-full", row.dot]} aria-hidden="true" />
                  {row.state}
                </span>
              </:col>
              <:col :let={row} label="Detail" class="text-xs text-fg-muted" hide_below="3xl">
                {row.detail}
              </:col>
              <:col :let={row} label="Agent" class="w-48" hide_below="xl">
                <.chip_list id={"sample-chips-#{row.id}"} label="Accepts jobs" items={row.jobs}>
                  <:chip :let={job}>{job.key}</:chip>
                  <:detail :let={job}>
                    <span class="min-w-0 truncate font-mono">{job.key}</span>
                    <span class="text-fg-muted">{job.risk}</span>
                  </:detail>
                </.chip_list>
              </:col>
            </.table>
          </.ds_card>

          <.ds_card id="component-properties" title="Properties and segmented control">
            <div class="grid gap-6 md:grid-cols-2">
              <.properties id="sample-properties">
                <:item label="Lifecycle" on_edit={show_overlay("sample-panel")}>Active</:item>
                <:item label="Serial" on_edit={show_overlay("sample-panel")}>
                  <span class="font-mono">SN-0042</span>
                </:item>
                <:item label="Warranty" blank placeholder="Add end date" />
              </.properties>
              <div class="space-y-2">
                <p class="text-xs font-medium text-fg-muted">Rack face</p>
                <.segmented id="sample-segmented" label="Rack face">
                  <:option id="sample-front" patch={preview_path(@preview, %{})} active>
                    Front
                  </:option>
                  <:option id="sample-rear" patch={preview_path(@preview, %{})} active={false}>
                    Rear
                  </:option>
                </.segmented>
              </div>
            </div>
          </.ds_card>

          <.ds_card id="component-overlays" title="Overlays and feedback">
            <div class="flex flex-wrap items-center gap-2">
              <.button id="open-sample-panel" phx-click={show_overlay("sample-panel")}>
                Open side panel
              </.button>
              <.button
                id="open-sample-dialog"
                variant="danger"
                phx-click={show_overlay("sample-dialog")}
              >
                Open confirm dialog
              </.button>
              <.button
                id="show-info-flash"
                variant="ghost"
                phx-click="flash"
                phx-value-kind="info"
              >
                Info flash
              </.button>
              <.button
                id="show-error-flash"
                variant="ghost"
                phx-click="flash"
                phx-value-kind="error"
              >
                Error flash
              </.button>
            </div>
            <.divider label="or" />
            <.link href="#components" class="text-sm text-link hover:underline">
              An inline link
            </.link>
          </.ds_card>

          <.ds_card id="component-object-page" title="Object page">
            <div class="-mx-5 -mb-5 overflow-hidden border-t border-edge">
              <.object_page id="sample-object" title="compute-01" subtitle="SN-0042 · server">
                <:breadcrumb>Inventory / compute-01</:breadcrumb>
                <:icon><.icon name="hero-server-stack-mini" class="size-4" /></:icon>
                <:status>
                  <.status_strip
                    size="header"
                    lifecycle="active"
                    freshness={:current}
                    freshness_label="1m"
                    agent={:connected}
                  />
                </:status>
                <:actions><.button size="sm">Edit</.button></:actions>
                <:tab patch={preview_path(@preview, %{})} active>Overview</:tab>
                <:tab patch={preview_path(@preview, %{})} count={2}>Hardware</:tab>
                <p class="text-sm text-fg-muted">Domains contribute tabs rather than pages.</p>
                <:aside>
                  <.properties>
                    <:item label="Site">Frankfurt</:item>
                    <:item label="Rack">A-04, U12</:item>
                  </.properties>
                </:aside>
              </.object_page>
            </div>
          </.ds_card>
        </.ds_section>

        <.ds_section
          id="icons"
          title="Icons"
          description="Heroicons through the icon component; the mini set at size-4 in controls and size-3.5 beside text-xs."
        >
          <div class="flex flex-wrap gap-2">
            <span
              :for={name <- @icons}
              title={name}
              class="grid size-10 place-items-center rounded-md border border-edge bg-surface text-fg-muted"
            >
              <.icon name={name} class="size-4" />
            </span>
          </div>
        </.ds_section>

        <.side_panel
          id="sample-panel"
          title="Edit compute-01"
          description="Changes apply to the record, not observed evidence."
        >
          <.input id="panel-name" name="panel_name" value="compute-01" label="Name" />
          <:footer>
            <.button phx-click={hide_overlay("sample-panel")}>Cancel</.button>
            <.button variant="primary" phx-click={hide_overlay("sample-panel")}>Save</.button>
          </:footer>
        </.side_panel>

        <.confirm_dialog
          id="sample-dialog"
          title="Retire compute-01?"
          confirm_label="Retire"
          on_confirm="confirm"
        >
          It leaves active inventory, and its addresses return to the pool.
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :key, :atom, required: true
  attr :options, :list, required: true
  attr :preview, :map, required: true

  defp preview_switch(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-2">
      <span class="shrink-0 text-xs font-medium text-fg-muted">{@label}</span>
      <div class="min-w-0 overflow-x-auto">
        <.segmented id={@id} label={@label}>
          <:option
            :for={{value, text} <- @options}
            id={"#{@id}-#{value}"}
            patch={preview_path(@preview, %{@key => value})}
            active={Map.fetch!(@preview, @key) == value}
          >
            {text}
          </:option>
        </.segmented>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :inner_block, required: true

  defp ds_section(assigns) do
    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-title"} class="scroll-mt-20 space-y-4">
      <div>
        <h2 id={"#{@id}-title"} class="text-base font-semibold text-fg">{@title}</h2>
        <p class="mt-1 max-w-2xl text-sm text-fg-muted">{@description}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp ds_card(assigns) do
    ~H"""
    <div id={@id} class="space-y-4 rounded-lg border border-edge bg-surface p-5">
      <h3 class="text-sm font-medium text-fg">{@title}</h3>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :swatches, :list, required: true

  defp swatches(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <h3 class="text-xs font-medium text-fg-muted">{@title}</h3>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <div
          :for={{name, class, use} <- @swatches}
          id={"swatch-#{name}"}
          class="overflow-hidden rounded-lg border border-edge bg-surface"
        >
          <div class={["h-12 border-b border-edge", class]} />
          <div class="space-y-0.5 px-3 py-2">
            <p class="font-mono text-xs text-fg">{name}</p>
            <p class="text-xs text-fg-muted">{use}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp preview_path(preview, changes) do
    @path <> "?" <> URI.encode_query(Map.merge(preview, changes))
  end

  defp density_heading(preview, density) do
    ["px-4 py-2 font-medium", preview.density == density && "text-fg"]
  end

  defp pick(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp sample_form do
    to_form(%{"name" => "compute-01", "site" => "fra", "notes" => "", "monitored" => "true"},
      as: :sample
    )
  end

  # The list groups rows under a header row per site, the way saved views
  # group inventory; headers are ordinary stream entries placed first.
  defp with_group_headers(nodes) do
    nodes
    |> Enum.chunk_by(& &1.group)
    |> Enum.flat_map(fn [first | _] = group ->
      [%{id: "group-#{first.group}", header: %{label: first.group, count: length(group)}} | group]
    end)
  end
end
