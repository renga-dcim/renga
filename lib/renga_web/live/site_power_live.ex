defmodule RengaWeb.SitePowerLive do
  @moduledoc """
  A site's power page (RFD 10): its panels, the feeds each supplies, and how
  much of every feed may be used.

  Capacity keeps its unit: AC feeds in VA and DC feeds in W, never summed
  together. Each feed shows the allocated load on it (`Renga.Power.Load`),
  or why it is unknown, and opens a breakdown by load and three-phase leg.
  Beside it is the measured load from current power readings
  (`Renga.Power.Measured`), which counts only fresh, valid readings that
  cover the whole feed and otherwise says why it is unknown. A feed's
  breakdown also charts its measured load over time from the telemetry store
  (`Renga.Power.History`), which never feeds the figures beside it.
  Its "What fails" action lists the devices that would lose all supply or
  their redundancy if it failed (`Renga.Power.Redundancy`).
  People holding `dcim.edit` (owners and admins) add panels and add or edit
  feeds in side panels; everyone else reads. Those holding
  `organization.manage` (owners) also set the organization's default power
  factor here, which loads without their own convert to VA with.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM
  alias Renga.Inventory.Changes
  alias Renga.Power
  alias Renga.Power.Capacity
  alias Renga.Power.Feed
  alias Renga.Power.History
  alias Renga.Power.Load
  alias Renga.Power.Measured
  alias Renga.Power.PowerFactor
  alias Renga.Power.Redundancy
  alias RengaWeb.TrendComponents

  import RengaWeb.TrendComponents, only: [trend_chart: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    site = DCIM.get_site!(scope, id)
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       site: site,
       page_title: "#{site.resource.name} power",
       can_manage?: Renga.Authorization.allowed?(scope, "dcim.edit"),
       can_manage_organization?: Renga.Authorization.allowed?(scope, "organization.manage"),
       locations: DCIM.list_locations(scope, site.id),
       panel_form: panel_form(%{}),
       feed_form: feed_form(%{}),
       feed_panel: nil,
       editing_feed: nil,
       load_feed_id: nil,
       trend_range: "24h",
       trend: nil,
       failure: nil
     )
     |> load_panels()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(trend_range: TrendComponents.range(params["trend"]))
     |> load_trend()}
  end

  # The open feed's measured load over the chosen period.
  defp load_trend(%{assigns: %{load_feed_id: nil}} = socket), do: assign(socket, trend: nil)

  defp load_trend(socket) do
    case Enum.find(socket.assigns.feeds, &(&1.id == socket.assigns.load_feed_id)) do
      nil ->
        assign(socket, trend: nil)

      feed ->
        buckets =
          TrendComponents.load(
            socket.assigns.current_scope,
            History.feed_series(feed),
            socket.assigns.trend_range
          )

        assign(socket, trend: buckets)
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_panels(socket)}

  @impl true
  def handle_event("create_panel", %{"panel" => params}, socket) do
    attrs = %{
      site_id: socket.assigns.site.id,
      name: params["name"],
      location_id: blank_to_nil(params["location_id"]),
      description: blank_to_nil(params["description"])
    }

    socket.assigns.current_scope
    |> Power.create_panel(attrs)
    |> after_mutation(socket, "Panel created", "panel-panel")
  end

  # Opens the feed panel empty for a new feed on `panel_id`.
  def handle_event("new_feed", %{"panel_id" => panel_id}, socket) do
    panel = Enum.find(socket.assigns.panels, &(&1.id == panel_id))

    {:noreply,
     socket
     |> assign(feed_panel: panel, editing_feed: nil, feed_form: feed_form(%{}))}
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Power.get_feed!(socket.assigns.current_scope, id)
    panel = Enum.find(socket.assigns.panels, &(&1.id == feed.panel_id))

    {:noreply,
     socket
     |> assign(feed_panel: panel, editing_feed: feed, feed_form: feed_form(feed_params(feed)))}
  end

  def handle_event("show_load", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(load_feed_id: id) |> load_trend()}

  def handle_event("show_failure", %{"id" => id}, socket) do
    feed = Enum.find(socket.assigns.feeds, &(&1.id == id))
    {:noreply, assign(socket, failure: feed && failure(socket, feed))}
  end

  # The phase field follows the supply.
  def handle_event("feed_change", %{"feed" => params}, socket),
    do: {:noreply, assign(socket, feed_form: feed_form(params))}

  def handle_event("save_feed", %{"feed" => params}, socket) do
    attrs = feed_attrs(params)
    scope = socket.assigns.current_scope

    case socket.assigns.editing_feed do
      nil ->
        scope
        |> Power.create_feed(socket.assigns.feed_panel.id, attrs)
        |> after_mutation(socket, "Feed added", "feed-panel")

      %Feed{} = feed ->
        scope
        |> Power.update_feed(feed, attrs)
        |> after_mutation(socket, "Feed updated", "feed-panel")
    end
  end

  # Form fields arrive as text; any other shape is a malformed event and
  # changes nothing rather than clearing the default.
  def handle_event(
        "save_power_factor",
        %{"organization" => %{"default_power_factor" => value}},
        socket
      )
      when is_binary(value) do
    case Power.set_default_power_factor(
           socket.assigns.current_scope,
           blank_to_nil(String.trim(value))
         ) do
      {:ok, _organization} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default power factor saved")
         |> close_overlay("power-factor-panel")
         |> load_panels()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, power_factor_form: to_form(changeset, as: :organization))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are not allowed to change the organization's default power factor"
         )}
    end
  end

  def handle_event("save_power_factor", _params, socket), do: {:noreply, socket}

  defp after_mutation({:ok, _record}, socket, message, panel) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(panel_form: panel_form(%{}), editing_feed: nil)
     |> close_overlay(panel)
     |> load_panels()}
  end

  defp after_mutation({:error, %Ecto.Changeset{} = changeset}, socket, _message, _panel),
    do: {:noreply, put_flash(socket, :error, first_error(changeset))}

  defp after_mutation({:error, reason}, socket, _message, _panel),
    do: {:noreply, put_flash(socket, :error, mutation_error(reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:sites}
    >
      <.object_page id="site-power" title={@site.resource.name} subtitle={@site.slug}>
        <:breadcrumb>
          <.link navigate={~p"/places"} class="hover:text-fg">Places</.link>
        </:breadcrumb>
        <:icon><.icon name="hero-building-office-2" class="size-5" /></:icon>
        <:actions :if={@can_manage?}>
          <.button
            id="new-panel"
            size="sm"
            variant="primary"
            phx-click={show_overlay("panel-panel")}
          >
            New panel
          </.button>
        </:actions>
        <:tab navigate={~p"/places/sites/#{@site.id}"}>Overview</:tab>
        <:tab navigate={~p"/places/sites/#{@site.id}/power"} active count={length(@panels)}>
          Power
        </:tab>

        <div class="space-y-6">
          <p :if={@panels == []} id="power-empty" class="text-sm text-fg-muted">
            No power panels at this site yet.
            <span :if={@can_manage?}>Add a panel, then the feeds it supplies.</span>
          </p>

          <section
            :for={panel <- @panels}
            id={"panel-#{panel.id}"}
            class="space-y-2"
            aria-labelledby={"panel-#{panel.id}-name"}
          >
            <div class="flex flex-wrap items-baseline gap-x-2">
              <h2 id={"panel-#{panel.id}-name"} class="text-sm font-semibold text-fg">
                {panel.name}
              </h2>
              <span :if={panel.location} class="text-xs text-fg-muted">
                {panel.location.resource.name}
              </span>
              <span class="font-mono text-xs text-fg-muted">
                {capacity_summary(panel.feeds)}
              </span>
              <.button
                :if={@can_manage?}
                id={"new-feed-#{panel.id}"}
                size="sm"
                class="ml-auto"
                phx-click={
                  JS.push("new_feed", value: %{panel_id: panel.id}) |> show_overlay("feed-panel")
                }
              >
                Add feed
              </.button>
            </div>

            <.table
              id={"panel-#{panel.id}-feeds"}
              rows={panel.feeds}
              row_id={&"feed-#{&1.id}"}
              row_click={if @can_manage?, do: &edit_feed/1}
              class="rounded-lg border border-edge bg-surface"
            >
              <:col :let={feed} label="Feed">
                <span class="font-medium text-fg">{feed.name}</span>
                <span :if={feed.status != "active"} class="ml-1.5 text-xs text-fg-muted">
                  {String.capitalize(feed.status)}
                </span>
              </:col>
              <:col :let={feed} label="Supply" class="text-fg-muted">{supply_label(feed)}</:col>
              <:col
                :let={feed}
                label="Rating"
                class="whitespace-nowrap font-mono text-xs tabular-nums"
              >
                {rating_label(feed)}
              </:col>
              <:col :let={feed} label="Side" class="w-14">{side_label(feed.side)}</:col>
              <:col :let={feed} label="Rack" class="text-fg-muted" hide_below="2xl">
                {if feed.rack, do: feed.rack.resource.name, else: "—"}
              </:col>
              <:col :let={feed} label="Usable" class="whitespace-nowrap text-right">
                <span id={"feed-#{feed.id}-usable"} class="font-mono text-xs tabular-nums text-fg">
                  {usable_label(feed)}
                </span>
                <span class="block font-mono text-[11px] tabular-nums text-fg-muted">
                  {feed.max_utilization}% of {rated_label(feed)}
                </span>
              </:col>
              <:col :let={feed} label="Allocated" class="w-36">
                <.feed_load feed={feed} load={Map.fetch!(@loads, feed.id)} />
              </:col>
              <:col :let={feed} label="Measured" class="w-36">
                <.feed_measured feed={feed} measured={Map.fetch!(@measured, feed.id)} />
              </:col>
              <:action :let={feed}>
                <.button
                  id={"feed-#{feed.id}-failure"}
                  type="button"
                  size="sm"
                  variant="ghost"
                  aria-label={"What fails if #{feed.name} fails"}
                  class="whitespace-nowrap"
                  phx-click={
                    JS.push("show_failure", value: %{id: feed.id}) |> show_overlay("failure-panel")
                  }
                >
                  What fails
                </.button>
                <.button
                  :if={@can_manage?}
                  id={"feed-#{feed.id}-edit"}
                  type="button"
                  size="sm"
                  variant="ghost"
                  aria-label={"Edit #{feed.name}"}
                  phx-click={edit_feed(feed)}
                >
                  Edit
                </.button>
              </:action>
              <:empty>No feeds on this panel yet.</:empty>
            </.table>
          </section>
        </div>

        <:aside>
          <.properties id="site-power-properties" title="Power">
            <:item label="Panels">{length(@panels)}</:item>
            <:item label="Feeds">{length(@feeds)}</:item>
            <:item label="Usable AC" blank={is_nil(@totals[:va])} placeholder="No AC feeds">
              <span id="site-usable-va">{@totals[:va] && Capacity.format(@totals[:va], :va)}</span>
            </:item>
            <:item label="Usable DC" blank={is_nil(@totals[:w])} placeholder="No DC feeds">
              <span id="site-usable-w">{@totals[:w] && Capacity.format(@totals[:w], :w)}</span>
            </:item>
            <:item label="Default power factor">
              <span id="default-power-factor" class="inline-flex items-baseline gap-2">
                <span :if={@default_power_factor} class="font-mono tabular-nums">
                  {Decimal.to_string(@default_power_factor)}
                </span>
                <span :if={!@default_power_factor} class="text-fg-muted">Not set</span>
                <button
                  :if={@can_manage_organization?}
                  id="edit-default-power-factor"
                  type="button"
                  class="inline-flex min-h-tap min-w-tap cursor-pointer items-center justify-center text-xs text-link hover:underline"
                  phx-click={show_overlay("power-factor-panel")}
                >
                  {if @default_power_factor, do: "Change", else: "Set"}
                </button>
              </span>
            </:item>
          </.properties>
          <p class="text-xs text-fg-muted">
            AC capacity is apparent power: volts × amps, or √3 × line-to-line volts × amps for
            three-phase. DC capacity is volts × amps in watts. Each applies the feed's maximum
            utilization.
          </p>
          <p class="text-xs text-fg-muted">
            Allocated load sums the allocated draw of the devices downstream of each feed. It is
            planning data, not a measurement.
          </p>
          <p class="text-xs text-fg-muted">
            Measured load comes from power readings. It counts only fresh, valid readings that cover
            everything on the feed, and is unknown otherwise.
          </p>
        </:aside>
      </.object_page>

      <.side_panel id="load-panel" title={load_panel_title(@loads, @load_feed_id)}>
        <.load_details
          :if={@loads[@load_feed_id]}
          load={@loads[@load_feed_id]}
          measured={@measured[@load_feed_id]}
          default_power_factor={@default_power_factor}
          trend={@trend}
          trend_range={@trend_range}
          trend_patch={&~p"/places/sites/#{@site.id}/power?trend=#{&1}"}
        />
      </.side_panel>

      <.side_panel
        id="failure-panel"
        title={if @failure, do: "If #{@failure.feed.name} fails", else: "If this feed fails"}
      >
        <.failure_details :if={@failure} failure={@failure} />
      </.side_panel>

      <.side_panel
        :if={@can_manage_organization?}
        id="power-factor-panel"
        title="Default power factor"
      >
        <.form
          for={@power_factor_form}
          id="power-factor-form"
          phx-submit="save_power_factor"
          class="space-y-1"
        >
          <.input
            field={@power_factor_form[:default_power_factor]}
            type="number"
            min="0.001"
            max="1"
            step="0.001"
            label="Power factor"
            autocomplete="off"
          />
          <p class="text-xs text-fg-muted">
            Loads with no power factor of their own, from their hardware type or set on the port,
            convert watts to volt-amperes with this. Headroom that rests on it is labelled. Leave
            empty to assume nothing: those loads' volt-amperes stay unknown.
          </p>
          <.panel_actions panel="power-factor-panel" id="save-power-factor" label="Save" />
        </.form>
      </.side_panel>

      <.side_panel :if={@can_manage?} id="panel-panel" title="New panel">
        <.form for={@panel_form} id="new-panel-form" phx-submit="create_panel" class="space-y-1">
          <.input field={@panel_form[:name]} label="Name" required autocomplete="off" />
          <.input
            :if={@locations != []}
            field={@panel_form[:location_id]}
            type="select"
            label="Location (optional)"
            prompt="The site itself"
            options={Enum.map(@locations, &{&1.resource.name, &1.id})}
          />
          <.input field={@panel_form[:description]} label="Description" autocomplete="off" />
          <.panel_actions panel="panel-panel" id="create-panel" label="Create panel" />
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="feed-panel"
        title={feed_panel_title(@editing_feed, @feed_panel)}
      >
        <.form
          for={@feed_form}
          id="feed-form"
          phx-change="feed_change"
          phx-submit="save_feed"
          class="space-y-1"
        >
          <.input field={@feed_form[:name]} label="Name" required autocomplete="off" />
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@feed_form[:supply]}
              type="select"
              label="Supply"
              options={[{"AC", "ac"}, {"DC", "dc"}]}
            />
            <.input
              :if={@feed_form[:supply].value != "dc"}
              field={@feed_form[:phase]}
              type="select"
              label="Phase"
              options={[{"Single-phase", "single"}, {"Three-phase", "three"}]}
            />
          </div>
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@feed_form[:voltage]}
              type="number"
              step="any"
              min="0"
              label={voltage_label(@feed_form)}
              required
            />
            <.input
              field={@feed_form[:amperage]}
              type="number"
              step="any"
              min="0"
              label="Rated current (A)"
              required
            />
          </div>
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@feed_form[:max_utilization]}
              type="number"
              min="1"
              max="100"
              label="Max utilization (%)"
              required
            />
            <.input
              field={@feed_form[:side]}
              type="select"
              label="Side"
              prompt="None"
              options={[{"A", "a"}, {"B", "b"}]}
            />
          </div>
          <.input
            :if={@site.racks != []}
            field={@feed_form[:rack_id]}
            type="select"
            label="Rack (optional)"
            prompt="No rack"
            options={Enum.map(@site.racks, &{&1.resource.name, &1.id})}
          />
          <.input
            field={@feed_form[:status]}
            type="select"
            label="Status"
            options={Enum.map(Feed.statuses(), &{String.capitalize(&1), &1})}
          />
          <.panel_actions
            panel="feed-panel"
            id="save-feed"
            label={if @editing_feed, do: "Save feed", else: "Add feed"}
          />
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp edit_feed(feed),
    do: "edit_feed" |> JS.push(value: %{id: feed.id}) |> show_overlay("feed-panel")

  attr :feed, Feed, required: true
  attr :load, Load, required: true

  # The allocated load in a feed's row: a bar and share of usable capacity
  # when known, otherwise what is known and why the rest is not. Opens the
  # breakdown either way.
  defp feed_load(assigns) do
    assigns = assign(assigns, :percent, Load.percent(assigns.load))

    ~H"""
    <button
      id={"feed-#{@feed.id}-load"}
      type="button"
      data-status={@load.status}
      aria-label={"#{@feed.name} load: #{status_label(@load)}"}
      class="block min-h-tap w-full cursor-pointer rounded-sm text-left focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
      phx-click={JS.push("show_load", value: %{id: @feed.id}) |> show_overlay("load-panel")}
    >
      <span class="flex items-baseline justify-between gap-2 font-mono text-xs tabular-nums">
        <span class={[@load.status == :over && "font-medium text-crit", "text-fg"]}>
          {load_label(@load)}
        </span>
        <span :if={@percent} class={[@load.status == :over && "text-crit", "text-fg-muted"]}>
          {@percent}%
        </span>
      </span>
      <span
        :if={@percent}
        class="mt-1 block h-1.5 w-full overflow-hidden rounded-full bg-sunken"
        aria-hidden="true"
      >
        <span
          class={["block h-full rounded-full", bar_class(@load)]}
          style={"width: #{min(@percent, 100)}%"}
        />
      </span>
      <span class={[
        "block text-[11px]",
        if(@load.status == :over, do: "text-crit", else: "text-fg-muted")
      ]}>
        {load_note(@load)}
      </span>
    </button>
    """
  end

  attr :feed, Feed, required: true
  attr :measured, Measured, required: true

  # The measured load in a feed's row, like the allocated load beside it.
  defp feed_measured(assigns) do
    assigns = assign(assigns, :percent, Measured.percent(assigns.measured))

    ~H"""
    <button
      id={"feed-#{@feed.id}-measured"}
      type="button"
      data-status={@measured.status}
      aria-label={"#{@feed.name} measured load: #{measured_status_label(@measured)}"}
      class="block min-h-tap w-full cursor-pointer rounded-sm text-left focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
      phx-click={JS.push("show_load", value: %{id: @feed.id}) |> show_overlay("load-panel")}
    >
      <span class="flex items-baseline justify-between gap-2 font-mono text-xs tabular-nums">
        <span class={[@measured.status == :over && "font-medium text-crit", "text-fg"]}>
          {measured_label(@measured)}
        </span>
        <span :if={@percent} class={[@measured.status == :over && "text-crit", "text-fg-muted"]}>
          {@percent}%
        </span>
      </span>
      <span
        :if={@percent}
        class="mt-1 block h-1.5 w-full overflow-hidden rounded-full bg-sunken"
        aria-hidden="true"
      >
        <span
          class={[
            "block h-full rounded-full",
            if(@measured.status == :over, do: "bg-crit", else: "bg-accent")
          ]}
          style={"width: #{min(@percent, 100)}%"}
        />
      </span>
      <span class={[
        "block text-[11px]",
        if(@measured.status == :over, do: "text-crit", else: "text-fg-muted")
      ]}>
        {measured_note(@measured)}
      </span>
    </button>
    """
  end

  attr :failure, Redundancy.Failure, required: true

  defp failure_details(assigns) do
    ~H"""
    <div id="failure-details" class="space-y-5 text-sm">
      <p id="failure-summary" class="text-fg">
        {failure_summary(@failure)}
      </p>

      <p
        :if={@failure.untraced?}
        id="failure-untraced"
        class="rounded-md border border-warn-line bg-warn-fill px-3 py-2 text-xs text-warn-text"
      >
        Part of the chain below this feed cannot be followed, so devices there are missing from
        this list. Check outlets whose hardware type does not name the inlet that feeds them.
      </p>

      <section id="failure-loses-supply" aria-labelledby="failure-loses-supply-title">
        <h3 id="failure-loses-supply-title" class="mb-1 text-xs font-semibold text-fg">
          Lose all supply ({length(@failure.loses_supply)})
        </h3>
        <p :if={@failure.loses_supply == []} class="text-xs text-fg-muted">None.</p>
        <ul
          :if={@failure.loses_supply != []}
          class="divide-y divide-line rounded-md border border-crit-line"
        >
          <li
            :for={{resource, _feeds} <- @failure.loses_supply}
            id={"failure-supply-#{resource.id}"}
            class="px-3 py-2"
          >
            <.link
              navigate={~p"/inventory/#{resource.id}/power"}
              class="break-words font-medium text-link hover:underline"
            >
              {resource.name}
            </.link>
            <span class="block text-xs text-fg-muted">No other feed reaches it.</span>
          </li>
        </ul>
      </section>

      <section
        :if={@failure.uncertain != []}
        id="failure-uncertain"
        aria-labelledby="failure-uncertain-title"
      >
        <h3 id="failure-uncertain-title" class="mb-1 text-xs font-semibold text-fg">
          Might lose supply or redundancy ({length(@failure.uncertain)})
        </h3>
        <ul class="divide-y divide-line rounded-md border border-warn-line">
          <li
            :for={{resource, feeds, consequence} <- @failure.uncertain}
            id={"failure-uncertain-#{resource.id}"}
            class="px-3 py-2"
          >
            <.link
              navigate={~p"/inventory/#{resource.id}/power"}
              class="break-words font-medium text-link hover:underline"
            >
              {resource.name}
            </.link>
            <span class="block text-xs text-fg-muted">
              {uncertain_note(consequence, feeds)}
            </span>
          </li>
        </ul>
      </section>

      <section id="failure-loses-redundancy" aria-labelledby="failure-loses-redundancy-title">
        <h3 id="failure-loses-redundancy-title" class="mb-1 text-xs font-semibold text-fg">
          Lose redundancy ({length(@failure.loses_redundancy)})
        </h3>
        <p :if={@failure.loses_redundancy == []} class="text-xs text-fg-muted">None.</p>
        <ul
          :if={@failure.loses_redundancy != []}
          class="divide-y divide-line rounded-md border border-warn-line"
        >
          <li
            :for={{resource, feeds} <- @failure.loses_redundancy}
            id={"failure-redundancy-#{resource.id}"}
            class="px-3 py-2"
          >
            <.link
              navigate={~p"/inventory/#{resource.id}/power"}
              class="break-words font-medium text-link hover:underline"
            >
              {resource.name}
            </.link>
            <span class="block text-xs text-fg-muted">
              Still supplied by {Enum.map_join(feeds, ", ", &feed_with_side/1)}.
            </span>
          </li>
        </ul>
      </section>

      <p class="text-xs text-fg-muted">
        From recorded power paths: a device is redundant when its ports reach feeds on two sides.
        Live supply state from readings is not part of this.
      </p>
    </div>
    """
  end

  attr :load, Load, required: true
  attr :measured, Measured, default: nil
  attr :default_power_factor, Decimal, default: nil
  attr :trend, :list, default: nil
  attr :trend_range, :string, default: "24h"
  attr :trend_patch, :any, required: true

  defp load_details(assigns) do
    ~H"""
    <div id="load-details" class="space-y-5 text-sm">
      <.properties id="load-summary" title="Allocated load">
        <:item label="Status">
          <span id="load-status" class={@load.status == :over && "font-medium text-crit"}>
            {status_label(@load)}
          </span>
        </:item>
        <:item label="Allocated">
          <span id="load-allocated" class="font-mono tabular-nums">{load_label(@load)}</span>
        </:item>
        <:item label="Usable">
          <span class="font-mono tabular-nums">
            {Capacity.format(@load.capacity.usable, @load.capacity.unit)}
          </span>
        </:item>
        <:item label="Headroom" blank={is_nil(@load.headroom)} placeholder="Unknown">
          <span
            id="load-headroom"
            class={[
              "font-mono tabular-nums",
              @load.headroom && Decimal.negative?(@load.headroom) && "text-crit"
            ]}
          >
            {@load.headroom && headroom(@load.headroom, @load.capacity.unit)}
          </span>
        </:item>
      </.properties>

      <p
        :if={@load.uses_default?}
        id="load-default-power-factor"
        class="rounded-md border border-warn-line bg-warn-fill px-3 py-2 text-xs text-warn-text"
      >
        Rests on the organization's default power factor of {@default_power_factor &&
          Decimal.to_string(@default_power_factor)} for loads with none of their own, not on
        per-load values.
      </p>

      <ul :if={incomplete_reasons(@load) != []} id="load-incomplete" class="space-y-1 text-xs">
        <li :for={reason <- incomplete_reasons(@load)} class="text-fg-muted">{reason}</li>
      </ul>

      <section :if={@load.legs != []} id="load-legs" aria-labelledby="load-legs-title">
        <h3 id="load-legs-title" class="mb-1 text-xs font-semibold text-fg">Legs</h3>
        <ul class="divide-y divide-line rounded-md border border-edge">
          <li
            :for={leg <- @load.legs}
            id={"load-leg-#{leg.leg}"}
            class="flex items-baseline justify-between gap-3 px-3 py-2 font-mono text-xs tabular-nums"
          >
            <span class="font-sans font-medium text-fg">Leg {String.upcase(leg.leg)}</span>
            <span class="text-fg-muted">
              {Capacity.format(leg.va, :va, leg_rounding(leg))}{or_more(leg)}
            </span>
            <span class={leg_class(leg)}>
              {amps(leg.current, leg_rounding(leg))}{or_more(leg)} of {amps(leg.limit, :floor)}
            </span>
          </li>
        </ul>
        <p class="mt-1 text-xs text-fg-muted">
          Each leg's current is its volt-amperes over line-to-line volts / √3, against the
          feed's rated current at its maximum utilization.
        </p>
      </section>

      <section id="load-draws" aria-labelledby="load-draws-title">
        <h3 id="load-draws-title" class="mb-1 text-xs font-semibold text-fg">
          Loads ({length(@load.draws)})
        </h3>
        <p :if={@load.draws == []} id="load-draws-empty" class="text-xs text-fg-muted">
          {if @load.untraced?,
            do: "No load below this feed could be traced.",
            else: "Nothing is plugged in downstream of this feed."}
        </p>
        <ul :if={@load.draws != []} class="divide-y divide-line rounded-md border border-edge">
          <li :for={draw <- @load.draws} id={"load-draw-#{draw.port.id}"} class="px-3 py-2">
            <div class="flex items-baseline justify-between gap-3">
              <.link
                navigate={~p"/inventory/#{draw.port.resource_id}/power"}
                class="min-w-0 truncate font-medium text-link hover:underline"
              >
                {draw.port.resource.name} · {draw.port.name}
              </.link>
              <span class="shrink-0 font-mono text-xs tabular-nums text-fg">
                {draw_label(draw, @load.capacity.unit)}
              </span>
            </div>
            <p class="text-xs text-fg-muted">{draw_note(draw, @load)}</p>
          </li>
        </ul>
      </section>

      <.measured_details :if={@measured} measured={@measured} />

      <.trend_chart
        :if={@measured}
        id="measured-trend"
        title="Measured load over time"
        buckets={@trend}
        unit={Capacity.unit_label(Capacity.unit(@measured.feed))}
        limit={@measured.capacity.usable}
        limit_label="usable capacity"
        range={@trend_range}
        patch={@trend_patch}
      />

      <p class="text-xs text-fg-muted">
        Allocated load is planning data. Neither it nor a watt total alone proves that another
        device can safely be connected.
      </p>
    </div>
    """
  end

  attr :measured, Measured, required: true

  defp measured_details(assigns) do
    ~H"""
    <section id="measured-details" class="space-y-3">
      <.properties id="measured-summary" title="Measured load">
        <:item label="Status">
          <span id="measured-status" class={@measured.status == :over && "font-medium text-crit"}>
            {measured_status_label(@measured)}
          </span>
        </:item>
        <:item label="Measured">
          <span id="measured-load" class="font-mono tabular-nums">
            {measured_label(@measured)}
          </span>
        </:item>
        <:item label="Headroom" blank={is_nil(@measured.headroom)} placeholder="Unknown">
          <span
            id="measured-headroom"
            class={[
              "font-mono tabular-nums",
              @measured.headroom && Decimal.negative?(@measured.headroom) && "text-crit"
            ]}
          >
            {@measured.headroom && headroom(@measured.headroom, @measured.capacity.unit)}
          </span>
        </:item>
        <:item :if={@measured.current} label="Current">
          <span id="measured-current" class="font-mono tabular-nums">
            {amps(@measured.current, :ceiling)} of {amps(@measured.current_limit, :floor)}
          </span>
        </:item>
        <:item label="Measured at" blank={is_nil(@measured.basis)} placeholder="—">
          <span id="measured-basis">{basis_label(@measured)}</span>
        </:item>
        <:item label="As of" blank={is_nil(@measured.as_of)} placeholder="—">
          <time
            :if={@measured.as_of}
            id="measured-as-of"
            datetime={DateTime.to_iso8601(@measured.as_of)}
          >
            {RengaWeb.Format.datetime(@measured.as_of)}
          </time>
        </:item>
      </.properties>

      <ul :if={@measured.gaps != []} id="measured-gaps" class="space-y-1 text-xs">
        <li :for={gap <- @measured.gaps} class="text-fg-muted">{gap_reason(gap)}</li>
      </ul>

      <ul
        :if={@measured.legs != []}
        id="measured-legs"
        class="divide-y divide-line rounded-md border border-edge"
      >
        <li
          :for={leg <- @measured.legs}
          id={"measured-leg-#{leg.leg}"}
          class="flex items-baseline justify-between gap-3 px-3 py-2 font-mono text-xs tabular-nums"
        >
          <span class="font-sans font-medium text-fg">Leg {String.upcase(leg.leg)}</span>
          <span :if={leg.current} class={measured_leg_class(leg)}>
            {amps(leg.current, :ceiling)} of {amps(leg.limit, :floor)}
          </span>
          <span :if={!leg.current} class="text-fg-muted">Not measured</span>
        </li>
      </ul>
    </section>
    """
  end

  attr :panel, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp panel_actions(assigns) do
    ~H"""
    <div class="mt-4 flex justify-end gap-2">
      <.button type="button" phx-click={hide_overlay(@panel)}>Cancel</.button>
      <.button id={@id} variant="primary" phx-disable-with="Saving…">{@label}</.button>
    </div>
    """
  end

  defp load_panels(socket) do
    panels = Power.list_panels(socket.assigns.current_scope, socket.assigns.site.id)
    feeds = Enum.flat_map(panels, & &1.feeds)
    default_power_factor = Power.default_power_factor(socket.assigns.current_scope)

    # An open "What fails" panel follows changes like the rest of the page.
    failure =
      with %Redundancy.Failure{feed: %{id: id}} <- socket.assigns[:failure],
           %Feed{} = feed <- Enum.find(feeds, &(&1.id == id)),
           do: failure(socket, feed)

    assign(socket,
      panels: panels,
      feeds: feeds,
      failure: failure,
      loads: Load.for_feeds(socket.assigns.current_scope, feeds, default_power_factor),
      measured: Measured.for_feeds(socket.assigns.current_scope, feeds),
      totals: Power.capacity_totals(feeds),
      default_power_factor: default_power_factor,
      power_factor_form:
        to_form(%{"default_power_factor" => default_power_factor || ""}, as: :organization)
    )
    # An open trend follows its feed: a feed whose supply changed now reads
    # another series, in another unit.
    |> load_trend()
  end

  defp panel_form(params) do
    %{"name" => "", "location_id" => "", "description" => ""}
    |> Map.merge(params)
    |> to_form(as: :panel)
  end

  defp feed_form(params) do
    %{
      "name" => "",
      "supply" => "ac",
      "phase" => "single",
      "voltage" => "",
      "amperage" => "",
      "max_utilization" => "80",
      "side" => "",
      "rack_id" => "",
      "status" => "active"
    }
    |> Map.merge(params)
    |> to_form(as: :feed)
  end

  defp feed_params(%Feed{} = feed) do
    %{
      "name" => feed.name,
      "supply" => feed.supply,
      "phase" => feed.phase || "single",
      "voltage" => Decimal.to_string(feed.voltage, :normal),
      "amperage" => Decimal.to_string(feed.amperage, :normal),
      "max_utilization" => Integer.to_string(feed.max_utilization),
      "side" => feed.side || "",
      "rack_id" => feed.rack_id || "",
      "status" => feed.status
    }
  end

  defp feed_attrs(params) do
    %{
      name: params["name"],
      supply: params["supply"],
      phase: blank_to_nil(params["phase"]),
      voltage: params["voltage"],
      amperage: params["amperage"],
      max_utilization: params["max_utilization"],
      side: blank_to_nil(params["side"]),
      rack_id: blank_to_nil(params["rack_id"]),
      status: params["status"]
    }
  end

  defp feed_panel_title(nil, nil), do: "New feed"
  defp feed_panel_title(nil, panel), do: "New feed on #{panel.name}"
  defp feed_panel_title(%Feed{name: name}, _panel), do: "Edit #{name}"

  defp voltage_label(form) do
    case {form[:supply].value, form[:phase].value} do
      {"dc", _phase} -> "Voltage (V)"
      {_ac, "three"} -> "Line-to-line voltage (V)"
      _single -> "Voltage (V)"
    end
  end

  defp supply_label(%Feed{supply: "dc"}), do: "DC"
  defp supply_label(%Feed{phase: "three"}), do: "AC · three-phase"
  defp supply_label(%Feed{}), do: "AC · single-phase"

  defp rating_label(feed),
    do: "#{number(feed.voltage)} V · #{number(feed.amperage)} A"

  defp side_label(nil), do: "—"
  defp side_label(side), do: String.upcase(side)

  defp usable_label(feed) do
    capacity = Capacity.of(feed)
    Capacity.format(capacity.usable, capacity.unit)
  end

  defp rated_label(feed) do
    capacity = Capacity.of(feed)
    Capacity.format(capacity.rated, capacity.unit)
  end

  defp failure(socket, feed), do: Redundancy.feed_failure(socket.assigns.current_scope, feed)

  defp failure_summary(failure) do
    supply = length(failure.loses_supply)
    redundancy = length(failure.loses_redundancy)
    uncertain = length(failure.uncertain)

    cond do
      supply + redundancy + uncertain + failure.keeps == 0 ->
        "No devices are recorded below #{failure.feed.name}."

      uncertain > 0 ->
        "#{supply} #{plural(supply, "device")} would lose all supply, #{redundancy} would lose redundancy, and #{uncertain} might, depending on paths that cannot be traced."

      supply + redundancy == 0 ->
        "Every device below #{failure.feed.name} keeps supply without losing redundancy."

      true ->
        "#{supply} #{plural(supply, "device")} would lose all supply and #{redundancy} would lose redundancy."
    end
  end

  defp uncertain_note(:supply, _feeds),
    do: "Loses all supply unless a path that cannot be traced reaches another feed."

  defp uncertain_note(:redundancy, feeds),
    do:
      "Still supplied by #{Enum.map_join(feeds, ", ", &feed_with_side/1)}. Paths that cannot be traced leave whether it loses redundancy unknown."

  defp feed_with_side(%{side: nil} = feed), do: feed.name
  defp feed_with_side(feed), do: "#{feed.name} (side #{String.upcase(feed.side)})"

  defp load_panel_title(loads, id) do
    case loads[id] do
      %Load{feed: feed} -> "#{feed.name} load"
      nil -> "Feed load"
    end
  end

  defp load_label(%Load{load: %Decimal{} = load, capacity: capacity}),
    do: Capacity.format(load, capacity.unit, :ceiling)

  defp load_label(%Load{status: :over} = load),
    do: "#{Capacity.format(load.known, load.capacity.unit)} or more"

  defp load_label(%Load{}), do: "Unknown"

  defp load_note(%Load{status: :over} = load) do
    if over_usable?(load),
      do: "Over usable capacity#{if load.uses_default?, do: " · default power factor"}",
      else: "A leg is over its limit"
  end

  defp load_note(%Load{status: :unknown, load: %Decimal{}}), do: "Legs not all known"
  defp load_note(%Load{status: :unknown} = load), do: hd(short_reasons(load))
  defp load_note(%Load{uses_default?: true}), do: "Default power factor"
  defp load_note(%Load{draws: []}), do: "Nothing plugged in"
  defp load_note(%Load{draws: draws}), do: "#{length(draws)} #{plural(length(draws), "load")}"

  defp short_reasons(load) do
    [
      load.untraced? && "Chain not traced",
      load.unallocated > 0 && "#{load.unallocated} without allocation",
      load.unconverted > 0 && "#{load.unconverted} without power factor"
    ]
    |> Enum.filter(& &1)
  end

  defp incomplete_reasons(load) do
    [
      load.untraced? &&
        "Part of the chain below this feed cannot be followed: a device whose hardware type does not name the inlet that feeds its outlets, or a chain deeper than any power train.",
      load.unallocated > 0 &&
        "#{load.unallocated} #{plural(load.unallocated, "load")} #{verb(load.unallocated, "has", "have")} no allocated draw. Set one on the device's power ports or its hardware type.",
      load.unconverted > 0 &&
        "#{load.unconverted} #{plural(load.unconverted, "load")} #{verb(load.unconverted, "has", "have")} no power factor, so #{verb(load.unconverted, "its", "their")} volt-amperes are unknown. Set one on the port, its hardware type, or as the organization default.",
      load.unassigned_legs > 0 &&
        "#{load.unassigned_legs} #{plural(load.unassigned_legs, "load")} #{verb(load.unassigned_legs, "is", "are")} on an outlet with no leg, so leg currents are incomplete."
    ]
    |> Enum.filter(& &1)
  end

  defp measured_label(%Measured{load: %Decimal{} = load, capacity: capacity}),
    do: Capacity.format(load, capacity.unit, :ceiling)

  defp measured_label(%Measured{known: %Decimal{} = known, capacity: capacity}),
    do: "#{Capacity.format(known, capacity.unit)} or more"

  defp measured_label(%Measured{status: :over, current: %Decimal{} = current}),
    do: amps(current, :ceiling)

  defp measured_label(%Measured{}), do: "Unknown"

  defp measured_status_label(%Measured{status: :ok}), do: "Within capacity"
  defp measured_status_label(%Measured{status: :unknown}), do: "Unknown"

  defp measured_status_label(%Measured{status: :over} = measured) do
    cond do
      measured.known && Decimal.gt?(measured.known, measured.capacity.usable) ->
        "Over capacity"

      measured.current && Decimal.gt?(measured.current, measured.current_limit) ->
        "Current over its limit"

      true ->
        "A leg is over its limit"
    end
  end

  defp measured_note(%Measured{status: :over} = measured), do: measured_status_label(measured)
  defp measured_note(%Measured{status: :ok} = measured), do: basis_label(measured)
  defp measured_note(%Measured{gaps: [gap | _rest]}), do: short_gap(gap)
  defp measured_note(%Measured{}), do: "No readings"

  defp basis_label(%Measured{basis: :aggregate}), do: "PDU inlet meter"
  defp basis_label(%Measured{basis: :outlets}), do: "Sum of PDU outlets"
  defp basis_label(%Measured{basis: :supply}), do: "Power supply input"
  defp basis_label(%Measured{}), do: nil

  defp short_gap(:no_cable), do: "Nothing connected"
  defp short_gap(:no_readings), do: "No readings"
  defp short_gap(:ineligible), do: "Readings stale or failed"
  defp short_gap(:partial_coverage), do: "Partial coverage"
  defp short_gap(:unconverted), do: "No measured power factor"
  defp short_gap(:legs_unmeasured), do: "Legs not all measured"

  defp short_gap({:outlets_unmeasured, count}),
    do: "#{count} #{plural(count, "outlet")} unmeasured"

  defp short_gap({:outlets_unmapped, count}),
    do: "#{count} #{plural(count, "outlet")} without an inlet"

  defp gap_reason(:no_cable), do: "Nothing is connected to this feed."

  defp gap_reason(:no_readings),
    do: "No power readings cover what this feed supplies."

  defp gap_reason(:ineligible),
    do:
      "Some readings are stale, failed, or unusable. Only fresh, valid readings count, and missing ones are never read as zero."

  defp gap_reason(:partial_coverage),
    do:
      "A reading declares that it covers only part of what it measures, so it is not used as this feed's load."

  defp gap_reason(:unconverted),
    do:
      "Real power was measured but not apparent power or a power factor, so the volt-amperes this AC feed is rated in are unknown."

  defp gap_reason(:legs_unmeasured),
    do:
      "Not every leg's current is measured. A three-phase total cannot show any one leg's headroom."

  defp gap_reason({:outlets_unmeasured, count}),
    do:
      "#{count} #{plural(count, "outlet")} on the PDU #{verb(count, "has", "have")} no fresh, valid reading, so the sum of outlets is only a lower bound."

  defp gap_reason({:outlets_unmapped, count}),
    do:
      "#{count} #{plural(count, "outlet")} on the PDU #{verb(count, "names", "name")} no inlet in the hardware type, so #{verb(count, "it", "they")} may draw from this feed and the sum of outlets is only a lower bound."

  defp measured_leg_class(%Measured.Leg{} = leg),
    do: if(Decimal.gt?(leg.current, leg.limit), do: "font-medium text-crit", else: "text-fg")

  defp status_label(%Load{status: :ok}), do: "Within capacity"

  defp status_label(%Load{status: :over} = load),
    do: if(over_usable?(load), do: "Over capacity", else: "A leg is over its limit")

  defp status_label(%Load{status: :unknown}), do: "Unknown"

  defp over_usable?(load), do: Decimal.gt?(load.known, load.capacity.usable)

  defp bar_class(%Load{status: :over}), do: "bg-crit"
  defp bar_class(%Load{status: :unknown}), do: "bg-fg-subtle"
  defp bar_class(%Load{uses_default?: true}), do: "bg-warn"
  defp bar_class(%Load{}), do: "bg-accent"

  defp leg_class(%Load.Leg{} = leg),
    do: if(Decimal.gt?(leg.current, leg.limit), do: "font-medium text-crit", else: "text-fg")

  defp draw_label(%Load.Draw{watts: nil}, _unit), do: "No allocation"
  defp draw_label(%Load.Draw{watts: watts}, :w), do: "#{Capacity.format(Decimal.new(watts), :w)}"

  defp draw_label(%Load.Draw{watts: watts, va: nil}, :va),
    do: "#{Capacity.format(Decimal.new(watts), :w)} · VA unknown"

  defp draw_label(%Load.Draw{watts: watts, va: va}, :va),
    do: "#{Capacity.format(Decimal.new(watts), :w)} · #{Capacity.format(va, :va, :ceiling)}"

  defp draw_note(draw, load) do
    [
      load.capacity.unit == :va && power_factor_note(draw.power_factor),
      load.legs != [] && if(draw.leg, do: "Leg #{String.upcase(draw.leg)}", else: "No leg")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp power_factor_note(nil), do: "No power factor"

  defp power_factor_note(%PowerFactor{} = power_factor),
    do:
      "Power factor #{Decimal.to_string(power_factor.value)}, #{PowerFactor.source_label(power_factor.source)}"

  # Rounded down, so headroom is never overstated and an overload never
  # understated: -0.4 VA reads as −1 VA.
  defp headroom(value, unit) do
    whole = Decimal.round(value, 0, :floor)

    if Decimal.negative?(whole),
      do: "−#{Capacity.format(Decimal.abs(whole), unit)}",
      else: Capacity.format(whole, unit)
  end

  # A complete leg's figures round up, so a current just over its limit never
  # reads as equal to it; a lower bound ("or more") rounds down to stay one.
  defp leg_rounding(%Load.Leg{complete?: true}), do: :ceiling
  defp leg_rounding(%Load.Leg{}), do: :floor

  defp or_more(%Load.Leg{complete?: true}), do: nil
  defp or_more(%Load.Leg{}), do: " or more"

  defp amps(value, rounding),
    do: "#{value |> Decimal.round(1, rounding) |> Decimal.to_string(:normal)} A"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp verb(1, one, _many), do: one
  defp verb(_count, _one, many), do: many

  defp capacity_summary([]), do: nil

  defp capacity_summary(feeds) do
    feeds
    |> Power.capacity_totals()
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {unit, total} -> "#{Capacity.format(total, unit)} usable" end)
  end

  defp number(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp mutation_error(:forbidden), do: "You are not allowed to manage power inventory"
  defp mutation_error(:rack_not_at_site), do: "The rack must be at this site"
  defp mutation_error(:location_not_at_site), do: "The location must be at this site"
  defp mutation_error(_reason), do: "Power inventory could not be updated"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, &translate_error/1) do
      errors when map_size(errors) == 0 ->
        "Power inventory could not be updated"

      errors ->
        {field, [message | _rest]} = Enum.min_by(errors, &elem(&1, 0))
        "#{Phoenix.Naming.humanize(field)} #{message}"
    end
  end
end
