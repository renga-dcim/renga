defmodule RengaWeb.SitePowerLive do
  @moduledoc """
  A site's power page (RFD 10): its panels, the feeds each supplies, and how
  much of every feed may be used.

  Capacity keeps its unit: AC feeds in VA and DC feeds in W, never summed
  together. Owners and admins add panels and add or edit feeds in side
  panels; everyone else reads.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM
  alias Renga.Inventory.Changes
  alias Renga.Power
  alias Renga.Power.Capacity
  alias Renga.Power.Feed

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
       can_manage?: Renga.Inventory.organization_manager?(scope),
       locations: DCIM.list_locations(scope, site.id),
       panel_form: panel_form(%{}),
       feed_form: feed_form(%{}),
       feed_panel: nil,
       editing_feed: nil
     )
     |> load_panels()}
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
              <:col :let={feed} label="Rating" class="font-mono text-xs tabular-nums">
                {rating_label(feed)}
              </:col>
              <:col :let={feed} label="Side" class="w-14">{side_label(feed.side)}</:col>
              <:col :let={feed} label="Rack" class="text-fg-muted" hide_below="2xl">
                {if feed.rack, do: feed.rack.resource.name, else: "—"}
              </:col>
              <:col :let={feed} label="Usable" class="text-right">
                <span id={"feed-#{feed.id}-usable"} class="font-mono text-xs tabular-nums text-fg">
                  {usable_label(feed)}
                </span>
                <span class="block font-mono text-[11px] tabular-nums text-fg-muted">
                  {feed.max_utilization}% of {rated_label(feed)}
                </span>
              </:col>
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
          </.properties>
          <p class="text-xs text-fg-muted">
            AC capacity is apparent power: volts × amps, or √3 × line-to-line volts × amps for
            three-phase. DC capacity is volts × amps in watts. Each applies the feed's maximum
            utilization.
          </p>
        </:aside>
      </.object_page>

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
    assign(socket, panels: panels, feeds: feeds, totals: Power.capacity_totals(feeds))
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
