defmodule RengaWeb.ResourcePowerLive do
  @moduledoc """
  A device's Power tab (RFD 10 phase 2): the power ports where power comes
  in and the outlets where it goes out, as its hardware type defines them.

  A port shows its maximum draw and allocated draw in W, and the power
  factor its load converts to VA with, labelled by where it comes from
  (RFD 10 phase 3). Both default from the catalog template; owners and
  admins can override them per port in a side panel, and clearing an
  override restores the default.

  Each port shows its power path: the outlets and PDUs it passes through on
  the way to a panel feed, or where that path stops. A device with more than
  one port shows whether those paths make it redundant, by the sides of the
  feeds they reach (`Renga.Power.Redundancy`). Each outlet shows what
  it powers. Owners and admins record a connection or unplug
  one; both are confirmed power cable claims (RFD 10 phase 2b).

  Power readings about the device (RFD 10 phase 4), such as a host's input
  power or a supply's status, are listed with the source and mapping that
  produced them and whether they are current. A supply's own input reading
  and status also show on its port. Readings are evidence: they never
  change the device's paths or redundancy. Telemetry does not announce
  itself and readings expire with time alone, so a connected page reloads
  its readings on a timer rather than waiting for an inventory change.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents

  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Paths
  alias Renga.Power.Port
  alias Renga.Power.PowerFactor
  alias Renga.Power.Reading
  alias Renga.Power.Readings
  alias Renga.Power.Redundancy

  @readings_refresh_ms 30_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_operational_resource!(scope, id)
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       resource: resource,
       page_title: "#{resource.name} power",
       hardware?: Catalog.hardware_assignable_resource?(resource),
       can_manage?: Renga.Authorization.allowed?(scope, "dcim.edit"),
       can_connect?: Renga.Authorization.allowed?(scope, "topology.edit"),
       editing_port: nil,
       allocation_form: allocation_form(nil),
       connecting_port: nil,
       connect_form: to_form(%{"target" => ""}, as: :connection),
       connect_error: nil,
       connect_options: [],
       suggested?: false,
       suggested_target: nil,
       selected_path: nil
     )
     |> load_endpoints()
     |> schedule_readings_refresh()}
  end

  # A suggested connection's finding links here with its port and outlet,
  # and the connect panel opens with that outlet chosen. Nothing is recorded
  # until the operator saves it, and only while both ends are still free: a
  # suggestion never replaces a recorded connection.
  @impl true
  def handle_params(%{"connect" => port_id, "outlet" => outlet_id}, _uri, socket)
      when is_binary(port_id) and is_binary(outlet_id) do
    port = Enum.find(socket.assigns.ports, &(&1.id == port_id))
    options = if socket.assigns.can_connect?, do: connect_options(socket), else: []
    target = "outlet:#{outlet_id}"

    if port && option?(options, target) &&
         Cables.free?(socket.assigns.current_scope, port.id, outlet_id) do
      {:noreply,
       assign(socket,
         connecting_port: port,
         connect_form: to_form(%{"target" => target}, as: :connection),
         connect_error: nil,
         connect_options: options,
         suggested?: true,
         suggested_target: target
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp option?(options, value) do
    Enum.any?(options, fn {_group, choices} -> Enum.any?(choices, &(elem(&1, 1) == value)) end)
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_endpoints(socket)}

  def handle_info(:refresh_readings, socket),
    do: {:noreply, socket |> load_readings() |> schedule_readings_refresh()}

  @impl true
  def handle_event("edit_port", %{"id" => id}, socket) do
    port = Enum.find(socket.assigns.ports, &(&1.id == id))
    {:noreply, assign(socket, editing_port: port, allocation_form: allocation_form(port))}
  end

  def handle_event("connect_port", %{"id" => id}, socket) do
    port = Enum.find(socket.assigns.ports, &(&1.id == id))
    current = socket.assigns.cables_by_port[id]

    {:noreply,
     assign(socket,
       connecting_port: port,
       connect_form: to_form(%{"target" => target_value(current)}, as: :connection),
       connect_error: nil,
       connect_options: connect_options(socket),
       suggested?: false,
       suggested_target: nil
     )}
  end

  def handle_event("show_path", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_path: socket.assigns.paths_by_port[id])}
  end

  def handle_event("save_connection", %{"connection" => %{"target" => target}}, socket) do
    port = socket.assigns.connecting_port
    action = connection_action(port, socket.assigns.cables_by_port)
    result_label = if action == "Move", do: "moved", else: "connected"

    result =
      case target_attrs(target) do
        nil ->
          {:error, :power_cable_endpoints}

        attrs ->
          Cables.connect(
            socket.assigns.current_scope,
            Map.put(attrs, :power_port_id, port.id),
            free_only: target == socket.assigns.suggested_target
          )
      end

    case result do
      {:ok, _assertion} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{port.name} #{result_label}")
         |> assign(
           connecting_port: nil,
           connect_error: nil,
           suggested?: false,
           suggested_target: nil
         )
         |> close_overlay("connect-panel")
         |> load_endpoints()}

      {:error, reason} ->
        {:noreply, assign(socket, connect_error: connection_error(reason))}
    end
  end

  def handle_event("unplug_port", %{"id" => id}, socket) do
    case Cables.disconnect_current(socket.assigns.current_scope, id) do
      {:ok, _retraction} ->
        {:noreply, socket |> put_flash(:info, "Unplugged") |> load_endpoints()}

      {:error, :power_connection_stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "That connection has already changed")
         |> load_endpoints()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, connection_error(reason))}
    end
  end

  # Form fields arrive as text; any other shape is a malformed event and
  # changes nothing rather than clearing an override.
  def handle_event(
        "save_allocation",
        %{"allocation" => %{"allocated_draw_w" => watts, "power_factor" => power_factor}},
        socket
      )
      when is_binary(watts) and is_binary(power_factor) do
    attrs = %{allocated_draw_w: blank_to_nil(watts), power_factor: blank_to_nil(power_factor)}

    case Power.update_port_allocation(
           socket.assigns.current_scope,
           socket.assigns.editing_port,
           attrs
         ) do
      {:ok, _port} ->
        {:noreply,
         socket
         |> put_flash(:info, "Allocation saved")
         |> assign(editing_port: nil)
         |> close_overlay("allocation-panel")
         |> load_endpoints()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, allocation_form: to_form(changeset, as: :allocation))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage power inventory")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The allocation could not be saved")}
    end
  end

  def handle_event("save_allocation", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:inventory}
      content_class="p-0"
    >
      <.resource_frame resource={@resource} tab={:power} hardware?={@hardware?}>
        <div id="resource-power" class="space-y-8">
          <p
            :if={@ports == [] and @outlets == []}
            id="power-empty"
            class="rounded-lg border border-dashed border-edge px-4 py-10 text-center text-sm text-fg-muted"
          >
            This device's hardware type defines no power ports or outlets.
            <.link
              :if={@hardware?}
              navigate={~p"/inventory/#{@resource}/hardware"}
              class="text-link hover:underline"
            >
              Check its hardware type
            </.link>
          </p>

          <.redundancy redundancy={@redundancy} />

          <section :if={@ports != []} aria-labelledby="power-ports-heading" class="space-y-2">
            <div class="flex items-baseline justify-between gap-4">
              <h2 id="power-ports-heading" class="text-sm font-semibold">Power ports</h2>
              <p id="power-allocated-total" class="text-sm text-fg-muted">
                <span :if={@allocated_total}>
                  <span class="font-mono tabular-nums text-fg">{@allocated_total}</span> W allocated
                </span>
                <span :if={!@allocated_total} class="text-warn-text">
                  Allocation unknown for {@unallocated} of {length(@ports)} ports
                </span>
              </p>
            </div>
            <.table
              id="power-ports"
              rows={@ports}
              row_id={&"power-port-#{&1.id}"}
              overflow="clip"
            >
              <:col :let={port} label="Port" class="w-24 @3xl:w-32">
                <span class="font-mono">{port.name}</span>
                <span :if={port.label} class="ml-2 text-fg-muted">{port.label}</span>
              </:col>
              <:col
                :let={port}
                label="Connector"
                class="w-28 text-fg-muted"
                hide_below="5xl"
              >
                {port.connector || "—"}
              </:col>
              <:col
                :let={port}
                label="Maximum"
                class="w-24 text-right font-mono tabular-nums"
                hide_below="4xl"
              >
                {watts(port.maximum_draw_w)}
              </:col>
              <:col
                :let={port}
                label="Allocated"
                class="w-28 text-right"
                hide_below="3xl"
              >
                <span class="font-mono tabular-nums">{watts(Port.allocated_draw_w(port))}</span>
                <span
                  :if={port.allocated_draw_w}
                  class="ml-1 text-xs text-fg-muted"
                  title="Set on this device instead of from its hardware type"
                >
                  set here
                </span>
              </:col>
              <:col
                :let={port}
                label="Power factor"
                class="w-32 text-right"
                hide_below="5xl"
              >
                <span id={"power-factor-#{port.id}"}>
                  <.power_factor power_factor={PowerFactor.for_port(port, @default_power_factor)} />
                </span>
              </:col>
              <:col
                :let={port}
                label="Measured"
                class="w-32 text-right"
                hide_below="4xl"
              >
                <.port_supply id={"power-supply-#{port.id}"} supply={@supplies[port.name]} />
              </:col>
              <:col :let={port} label="Path" class="w-20 @3xl:w-auto" clip={false}>
                <button
                  id={"power-path-#{port.id}"}
                  type="button"
                  aria-label={
                    "View power path for #{port.name}: #{path_summary(@paths_by_port[port.id])}"
                  }
                  title={path_summary(@paths_by_port[port.id])}
                  phx-click={show_path(@paths_by_port[port.id])}
                  class="flex min-h-tap min-w-tap w-full items-center gap-1 rounded-sm text-left transition-colors hover:text-accent focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
                >
                  <span class={[
                    "min-w-0 flex-1 truncate",
                    @paths_by_port[port.id].stop not in [nil, :not_connected] && "text-warn-text",
                    @paths_by_port[port.id].stop == :not_connected && "text-fg-muted"
                  ]}>
                    {path_summary(@paths_by_port[port.id])}
                  </span>
                  <.icon name="hero-chevron-right-mini" class="size-4 shrink-0 text-fg-muted" />
                </button>
              </:col>
              <:action :let={port} :if={@can_manage? or @can_connect?}>
                <div class="flex justify-end gap-2">
                  <.button
                    :if={@can_manage?}
                    id={"power-port-#{port.id}-edit"}
                    type="button"
                    size="sm"
                    variant="ghost"
                    aria-label={"Edit allocation for #{port.name}"}
                    title={"Edit allocation for #{port.name}"}
                    class="min-w-tap"
                    phx-click={edit_port(port)}
                  >
                    <.icon name="hero-pencil-square-mini" class="size-4" />
                    <span class="hidden @3xl:inline">Edit</span>
                  </.button>
                  <.button
                    :if={@can_connect?}
                    id={"connect-port-#{port.id}"}
                    type="button"
                    size="sm"
                    aria-label={
                      if @cables_by_port[port.id],
                        do: "Move connection for #{port.name}",
                        else: "Connect #{port.name}"
                    }
                    title={if @cables_by_port[port.id], do: "Move connection", else: "Connect"}
                    class="min-w-tap"
                    phx-click={connect_port(port)}
                  >
                    <.icon
                      name={
                        if @cables_by_port[port.id],
                          do: "hero-arrows-right-left-mini",
                          else: "hero-link-mini"
                      }
                      class="size-4"
                    />
                    <span class="hidden @3xl:inline">
                      {if @cables_by_port[port.id], do: "Move", else: "Connect"}
                    </span>
                  </.button>
                  <.button
                    :if={@can_connect? and @cables_by_port[port.id]}
                    id={"unplug-port-#{port.id}"}
                    type="button"
                    size="sm"
                    aria-label={"Unplug #{port.name}"}
                    title={"Unplug #{port.name}"}
                    class="min-w-tap"
                    phx-click="unplug_port"
                    phx-value-id={@cables_by_port[port.id].id}
                  >
                    <.icon name="hero-link-slash-mini" class="size-4" />
                    <span class="hidden @3xl:inline">Unplug</span>
                  </.button>
                </div>
              </:action>
            </.table>
          </section>

          <section :if={@outlets != []} aria-labelledby="power-outlets-heading" class="space-y-2">
            <h2 id="power-outlets-heading" class="text-sm font-semibold">Outlets</h2>
            <.table id="power-outlets" rows={@outlets} row_id={&"power-outlet-#{&1.id}"}>
              <:col :let={outlet} label="Outlet">
                <span class="font-mono">{outlet.name}</span>
                <span :if={outlet.label} class="ml-2 text-fg-muted">{outlet.label}</span>
              </:col>
              <:col :let={outlet} label="Connector" class="text-fg-muted">
                {outlet.connector || "—"}
              </:col>
              <:col :let={outlet} label="Inlet" class="font-mono">
                {if outlet.inlet_port, do: outlet.inlet_port.name, else: "—"}
              </:col>
              <:col :let={outlet} label="Leg" class="w-14">
                {if outlet.feed_leg, do: String.upcase(outlet.feed_leg), else: "—"}
              </:col>
              <:col :let={outlet} label="Powers">
                <.outlet_connection cable={@cables_by_outlet[outlet.id]} />
              </:col>
            </.table>
          </section>

          <section :if={@readings != []} aria-labelledby="power-readings-heading" class="space-y-2">
            <div>
              <h2 id="power-readings-heading" class="text-sm font-semibold">Power readings</h2>
              <p class="text-xs text-fg-muted">
                The latest reading of each sensor, with the source that produced it. Only current
                readings count toward measured load; stale or failed ones are never read as zero.
              </p>
            </div>
            <.table
              id="power-readings"
              rows={@readings}
              row_id={&"power-reading-#{&1.reading.id}"}
              overflow="clip"
            >
              <:col :let={entry} label="Measures">
                <span class="text-fg">{measures_label(entry.reading)}</span>
                <span class="ml-2 font-mono text-xs text-fg-muted">{entry.reading.sensor}</span>
              </:col>
              <:col :let={entry} label="Value" class="w-24 text-right font-mono tabular-nums">
                {reading_value(entry.reading)}
              </:col>
              <:col :let={entry} label="Source" class="w-56" hide_below="4xl">
                <span class="text-fg">{entry.reading.source.name}</span>
                <span class="ml-2 font-mono text-xs text-fg-muted">
                  {mapping_label(entry.reading)}
                </span>
              </:col>
              <:col :let={entry} label="Taken" class="w-24" hide_below="xl">
                <time
                  datetime={DateTime.to_iso8601(entry.reading.event_at)}
                  title={RengaWeb.Format.datetime(entry.reading.event_at)}
                >
                  {RengaWeb.Format.age(entry.reading.event_at, @now)}
                </time>
              </:col>
              <:col :let={entry} label="Status" class="w-24">
                <span
                  id={"power-reading-#{entry.reading.id}-status"}
                  class={!entry.eligible? && "text-warn-text"}
                >
                  {reading_status(entry, @now)}
                </span>
              </:col>
            </.table>
          </section>

          <section
            :if={@retired_cables != []}
            aria-labelledby="retired-power-connections-heading"
            class="space-y-2"
          >
            <div>
              <h2 id="retired-power-connections-heading" class="text-sm font-semibold">
                Retired hardware connections
              </h2>
              <p class="text-xs text-fg-muted">
                These connections remain recorded although this hardware type no longer defines the
                local endpoint.
              </p>
            </div>
            <.table
              id="retired-power-connections"
              rows={@retired_cables}
              row_id={&"retired-power-connection-#{&1.id}"}
            >
              <:col :let={cable} label="Retired endpoint">
                <span class="font-mono">{retired_endpoint_label(cable, @resource.id)}</span>
              </:col>
              <:col :let={cable} label="Connected to">
                <.port_connection
                  :if={local_port?(cable, @resource.id)}
                  cable={cable}
                />
                <.outlet_connection
                  :if={!local_port?(cable, @resource.id)}
                  cable={cable}
                />
              </:col>
              <:action :let={cable} :if={@can_connect?}>
                <.button
                  id={"unplug-retired-cable-#{cable.id}"}
                  type="button"
                  size="sm"
                  phx-click="unplug_port"
                  phx-value-id={cable.id}
                >
                  Unplug
                </.button>
              </:action>
            </.table>
          </section>
        </div>
      </.resource_frame>

      <.side_panel
        id="path-panel"
        title={
          if @selected_path,
            do: "Power path for #{@selected_path.port.name}",
            else: "Power path"
        }
      >
        <div :if={@selected_path} id="power-path-detail" class="space-y-5">
          <div>
            <p class="text-xs font-medium text-fg-muted">Starts at</p>
            <p class="mt-1 break-words font-mono text-sm">
              {@resource.name} · {@selected_path.port.name}
            </p>
          </div>

          <ol :if={@selected_path.outlets != []} class="space-y-3" aria-label="Power path hops">
            <li
              :for={{outlet, index} <- Enum.with_index(@selected_path.outlets, 1)}
              class="flex items-start gap-3 border-l border-edge pl-4"
            >
              <span class="mt-1 font-mono text-xs text-fg-muted">{index}</span>
              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/inventory/#{outlet.resource}/power"}
                  class="flex min-h-tap min-w-tap w-full items-center rounded-sm text-link hover:underline focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
                >
                  <span class="min-w-0 break-words">{outlet.resource.name}</span>
                </.link>
                <p class="break-words text-sm">
                  Outlet <span class="font-mono">{outlet.name}</span>
                  <span :if={outlet.inlet_port} class="text-fg-muted">
                    via inlet <span class="font-mono">{outlet.inlet_port.name}</span>
                  </span>
                </p>
              </div>
            </li>
          </ol>

          <div
            :if={@selected_path.feed}
            id="power-path-terminal"
            class="rounded-lg border border-edge bg-sunken p-3"
          >
            <p class="text-xs font-medium text-fg-muted">Panel feed</p>
            <p class="mt-1 break-words text-sm">
              {@selected_path.feed.panel.name}
              <span class="font-mono">{@selected_path.feed.name}</span>
              <span :if={@selected_path.feed.side} class="ml-1 text-xs text-fg-muted">
                side {String.upcase(@selected_path.feed.side)}
              </span>
            </p>
          </div>

          <div
            :if={@selected_path.stop}
            id="power-path-terminal"
            class="rounded-lg border border-warn-line bg-warn-fill p-3 text-warn-text"
          >
            <p class="text-xs font-medium">Path stops here</p>
            <p class="mt-1 break-words text-sm">{stop_label(@selected_path)}</p>
          </div>
        </div>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="allocation-panel"
        title={if @editing_port, do: "Allocate #{@editing_port.name}", else: "Allocate"}
      >
        <.form
          for={@allocation_form}
          id="allocation-form"
          phx-submit="save_allocation"
          class="space-y-1"
        >
          <.input
            field={@allocation_form[:allocated_draw_w]}
            type="number"
            min="1"
            label="Allocated draw (W)"
            autocomplete="off"
          />
          <p :if={@editing_port} class="text-xs text-fg-muted">
            Leave empty to use the hardware type's {watts(@editing_port.default_allocated_draw_w)}.
          </p>
          <div class="pt-3">
            <.input
              field={@allocation_form[:power_factor]}
              type="number"
              min="0.001"
              max="1"
              step="0.001"
              label="Power factor"
              autocomplete="off"
            />
          </div>
          <p :if={@editing_port} id="power-factor-fallback" class="text-xs text-fg-muted">
            {power_factor_fallback(@editing_port, @default_power_factor)}
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("allocation-panel")}>Cancel</.button>
            <.button id="save-allocation" variant="primary" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_connect?}
        id="connect-panel"
        show={@suggested?}
        title={connection_title(@connecting_port, @cables_by_port)}
      >
        <.form for={@connect_form} id="connect-form" phx-submit="save_connection" class="space-y-1">
          <p :if={@suggested?} id="connect-suggested" class="mb-2 text-sm text-fg-muted">
            Power readings suggest this outlet. Check the cable before you record it.
          </p>
          <.input
            field={@connect_form[:target]}
            type="select"
            label="Plugged into"
            prompt="Choose an outlet or feed"
            options={@connect_options}
          />
          <p :if={@connect_error} id="connect-error" role="alert" class="text-sm text-crit">
            {@connect_error}
          </p>
          <p class="text-xs text-fg-muted">
            Recorded as a confirmed connection by you. Whatever this port or that outlet
            was plugged into before is replaced.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("connect-panel")}>Cancel</.button>
            <.button id="save-connection" variant="primary" phx-disable-with="Saving…">
              {connection_action(@connecting_port, @cables_by_port)}
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp path_summary(%{feed: %{panel: panel} = feed, outlets: outlets}),
    do: "#{panel.name} #{feed.name}#{hop_suffix(outlets)}"

  defp path_summary(%{stop: :not_connected}), do: "Not recorded"
  defp path_summary(path), do: "#{stop_label(path)}#{hop_suffix(path.outlets)}"

  defp hop_suffix([]), do: ""
  defp hop_suffix([_outlet]), do: " · 1 PDU hop"
  defp hop_suffix(outlets), do: " · #{length(outlets)} PDU hops"

  defp stop_label(%{stop: :not_connected}), do: "No connection is recorded"
  defp stop_label(%{stop: :inlet_unknown}), do: "No inlet mapped for this outlet"

  defp stop_label(%{stop: :inlet_not_connected, outlets: outlets}),
    do: "#{List.last(outlets).inlet_port.name} not connected"

  defp stop_label(%{stop: :loop}), do: "Loops back on itself"
  defp stop_label(%{stop: :too_deep}), do: "Too many hops to follow"

  attr :cable, :any, required: true

  defp port_connection(%{cable: %{power_outlet: %{}}} = assigns) do
    ~H"""
    <.link
      navigate={~p"/inventory/#{@cable.power_outlet.resource}/power"}
      class="text-link hover:underline"
    >
      {@cable.power_outlet.resource.name}
    </.link>
    <span class="font-mono">{@cable.power_outlet.name}</span>
    """
  end

  defp port_connection(assigns) do
    ~H"""
    <span>{@cable.power_feed.panel.name}</span>
    <span class="font-mono">{@cable.power_feed.name}</span>
    """
  end

  attr :cable, :any, required: true

  defp outlet_connection(%{cable: nil} = assigns),
    do: ~H"""
    <span class="text-fg-muted">—</span>
    """

  defp outlet_connection(assigns) do
    ~H"""
    <.link
      navigate={~p"/inventory/#{@cable.power_port.resource}/power"}
      class="text-link hover:underline"
    >
      {@cable.power_port.resource.name}
    </.link>
    <span class="font-mono">{@cable.power_port.name}</span>
    """
  end

  defp connect_port(port),
    do: "connect_port" |> JS.push(value: %{id: port.id}) |> show_overlay("connect-panel")

  defp connection_title(nil, _cables_by_port), do: "Connect"

  defp connection_title(port, cables_by_port),
    do: "#{connection_action(port, cables_by_port)} #{port.name}"

  defp connection_action(nil, _cables_by_port), do: "Connect"

  defp connection_action(port, cables_by_port),
    do: if(Map.has_key?(cables_by_port, port.id), do: "Move", else: "Connect")

  # Outlets grouped by device, then feeds grouped by panel; a value names
  # its kind so one select covers both.
  defp connect_options(socket) do
    %{outlets: outlets, feeds: feeds} =
      Cables.connectable(socket.assigns.current_scope, socket.assigns.resource.id)

    outlet_groups =
      outlets
      |> Enum.chunk_by(& &1.resource_id)
      |> Enum.map(fn [first | _] = group ->
        {first.resource.name, Enum.map(group, &{"Outlet #{&1.name}", "outlet:#{&1.id}"})}
      end)

    feed_groups =
      feeds
      |> Enum.chunk_by(& &1.panel_id)
      |> Enum.map(fn [first | _] = group ->
        {"Panel #{first.panel.name}", Enum.map(group, &{"Feed #{&1.name}", "feed:#{&1.id}"})}
      end)

    outlet_groups ++ feed_groups
  end

  defp target_value(nil), do: ""
  defp target_value(%{power_outlet_id: id}) when is_binary(id), do: "outlet:#{id}"
  defp target_value(%{power_feed_id: id}), do: "feed:#{id}"

  defp target_attrs("outlet:" <> id), do: %{power_outlet_id: id}
  defp target_attrs("feed:" <> id), do: %{power_feed_id: id}
  defp target_attrs(_target), do: nil

  defp local_port?(%{power_port: %{resource_id: resource_id}}, resource_id), do: true
  defp local_port?(_cable, _resource_id), do: false

  defp retired_endpoint_label(cable, resource_id) do
    if local_port?(cable, resource_id),
      do: "Port #{cable.power_port.name}",
      else: "Outlet #{cable.power_outlet.name}"
  end

  defp retired_for_resource?(cable, resource_id) do
    (local_port?(cable, resource_id) and not is_nil(cable.power_port.retired_at)) or
      match?(
        %{resource_id: ^resource_id, retired_at: retired_at} when not is_nil(retired_at),
        cable.power_outlet
      )
  end

  defp connection_error(:forbidden), do: "You are not allowed to manage power inventory"
  defp connection_error(:power_loop), do: "A device's outlet cannot power its own port"

  defp connection_error(:power_connection_occupied),
    do: "That port or outlet has been connected since this was suggested"

  defp connection_error(:power_endpoint_retired),
    do: "That port or outlet is no longer part of its hardware type"

  defp connection_error(_reason), do: "Choose an outlet or feed to connect"

  defp edit_port(port),
    do: "edit_port" |> JS.push(value: %{id: port.id}) |> show_overlay("allocation-panel")

  attr :redundancy, Redundancy, required: true

  defp redundancy(%{redundancy: %Redundancy{status: :none}} = assigns), do: ~H""

  defp redundancy(assigns) do
    ~H"""
    <p
      id="power-redundancy"
      data-status={@redundancy.status}
      class={[
        "flex items-start gap-2 rounded-md border px-3 py-2 text-sm",
        @redundancy.status in [:not_redundant, :unknown] &&
          "border-warn-line bg-warn-fill text-warn-text",
        @redundancy.status not in [:not_redundant, :unknown] && "border-edge bg-surface text-fg"
      ]}
    >
      <.icon
        name={redundancy_icon(@redundancy.status)}
        class={"mt-0.5 size-4 shrink-0 #{redundancy_icon_class(@redundancy.status)}"}
      />
      <span>
        <span class="font-medium">{redundancy_label(@redundancy)}</span>
        <span :if={redundancy_note(@redundancy)} class="block text-xs">
          {redundancy_note(@redundancy)}
        </span>
      </span>
    </p>
    """
  end

  defp redundancy_icon(:redundant), do: "hero-check-circle-mini"
  defp redundancy_icon(:not_redundant), do: "hero-exclamation-triangle-mini"
  defp redundancy_icon(:unknown), do: "hero-question-mark-circle-mini"
  defp redundancy_icon(:single_supply), do: "hero-minus-circle-mini"

  defp redundancy_icon_class(:redundant), do: "text-ok"
  defp redundancy_icon_class(:single_supply), do: "text-fg-muted"
  defp redundancy_icon_class(_status), do: ""

  defp redundancy_label(%Redundancy{status: :redundant, sides: sides}),
    do: "Redundant: reaches sides #{Enum.map_join(sides, " and ", &String.upcase/1)}"

  defp redundancy_label(%Redundancy{status: :not_redundant}), do: "Not redundant"
  defp redundancy_label(%Redundancy{status: :unknown}), do: "Redundancy unknown"
  defp redundancy_label(%Redundancy{status: :single_supply}), do: "Single supply"

  defp redundancy_note(%Redundancy{status: :redundant, feeds: feeds}),
    do: "Through #{Enum.map_join(feeds, ", ", &feed_with_side/1)}."

  defp redundancy_note(%Redundancy{status: status} = redundancy)
       when status in [:not_redundant, :unknown] do
    [
      named(redundancy.untraced, "has a path", "have paths", "that cannot be traced to a feed"),
      redundancy.feeds == [] && redundancy.untraced == [] && "No port reaches a feed yet",
      match?([_], redundancy.sides) &&
        "Every feed with a recorded side is on side #{String.upcase(hd(redundancy.sides))}",
      redundancy.feeds != [] && named(redundancy.unfed, "reaches", "reach", "no feed"),
      named(redundancy.sideless, "has", "have", "no side")
    ]
    |> Enum.filter(& &1)
    |> Enum.map_join(" ", &(&1 <> "."))
  end

  defp redundancy_note(%Redundancy{}), do: nil

  # "PSU2 reaches no feed", or nil when there is nothing to name.
  defp named([], _one, _many, _rest), do: nil

  defp named(items, one, many, rest) do
    verb = if match?([_], items), do: one, else: many
    "#{Enum.map_join(items, ", ", & &1.name)} #{verb} #{rest}"
  end

  defp feed_with_side(%{side: nil} = feed), do: feed.name
  defp feed_with_side(feed), do: "#{feed.name} (#{String.upcase(feed.side)})"

  defp show_path(path),
    do: "show_path" |> JS.push(value: %{id: path.port.id}) |> show_overlay("path-panel")

  defp load_endpoints(socket) do
    %{ports: ports, outlets: outlets} =
      Power.list_device_endpoints(socket.assigns.current_scope, socket.assigns.resource.id)

    cables =
      Cables.list_cables(socket.assigns.current_scope, resource_ids: [socket.assigns.resource.id])

    # A port retired from the hardware type keeps its cable, and with it its
    # supply, so redundancy follows it until it is unplugged.
    retired_cabled =
      for %{power_port: %Port{retired_at: retired_at} = port} <- cables,
          retired_at,
          port.resource_id == socket.assigns.resource.id,
          do: port

    paths = Paths.for_ports(socket.assigns.current_scope, ports ++ retired_cabled)
    default_power_factor = Power.default_power_factor(socket.assigns.current_scope)
    selected_path_id = socket.assigns.selected_path && socket.assigns.selected_path.port.id
    allocations = Enum.map(ports, &Port.allocated_draw_w/1)
    unallocated = Enum.count(allocations, &is_nil/1)

    socket
    |> assign(
      ports: ports,
      outlets: outlets,
      cables_by_port: Map.new(cables, &{&1.power_port_id, &1}),
      paths_by_port: Map.new(paths, &{&1.port.id, &1}),
      redundancy: Redundancy.of(paths),
      selected_path: Enum.find(paths, &(&1.port.id == selected_path_id)),
      cables_by_outlet:
        for(cable <- cables, cable.power_outlet_id, into: %{}, do: {cable.power_outlet_id, cable}),
      retired_cables: Enum.filter(cables, &retired_for_resource?(&1, socket.assigns.resource.id)),
      unallocated: unallocated,
      allocated_total: if(unallocated == 0, do: Enum.sum(allocations)),
      default_power_factor: default_power_factor
    )
    |> load_readings()
  end

  defp load_readings(socket) do
    now = Renga.Time.utc_now_ms()
    resource_id = socket.assigns.resource.id

    readings =
      socket.assigns.current_scope
      |> Readings.for_resources([resource_id], now)
      |> Map.get(resource_id, [])
      |> Enum.sort_by(
        &{&1.reading.boundary, &1.reading.component_name || "", &1.reading.leg || "",
         &1.reading.quantity, &1.reading.window_ms}
      )

    assign(socket, now: now, readings: readings, supplies: supplies(readings))
  end

  defp schedule_readings_refresh(socket) do
    if connected?(socket),
      do: Process.send_after(self(), :refresh_readings, @readings_refresh_ms)

    socket
  end

  defp allocation_form(nil),
    do: to_form(%{"allocated_draw_w" => "", "power_factor" => ""}, as: :allocation)

  defp allocation_form(%Port{} = port) do
    to_form(
      %{
        "allocated_draw_w" => port.allocated_draw_w || "",
        "power_factor" => port.power_factor || ""
      },
      as: :allocation
    )
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  attr :power_factor, PowerFactor, default: nil

  defp power_factor(%{power_factor: nil} = assigns) do
    ~H"""
    <span class="text-fg-muted" title="Volt-amperes for this load stay unknown">Not set</span>
    """
  end

  defp power_factor(assigns) do
    ~H"""
    <span class="font-mono tabular-nums">{Decimal.to_string(@power_factor.value)}</span>
    <span class="ml-1 text-xs text-fg-muted">{PowerFactor.source_label(@power_factor.source)}</span>
    """
  end

  # What clearing the override falls back to.
  defp power_factor_fallback(port, default) do
    case PowerFactor.for_port(%{port | power_factor: nil}, default) do
      nil ->
        "Leave empty to leave it unknown: neither the hardware type nor the organization sets one."

      %PowerFactor{source: :hardware_type, value: value} ->
        "Leave empty to use the hardware type's #{value}."

      %PowerFactor{source: :organization_default, value: value} ->
        "Leave empty to use the organization default of #{value}."
    end
  end

  attr :id, :string, required: true
  attr :supply, :map, default: nil

  # A supply's own input reading and status, when either is current.
  defp port_supply(assigns) do
    ~H"""
    <span id={@id} class="font-mono text-xs tabular-nums">
      <span :if={@supply && @supply.draw} class="text-fg">{@supply.draw}</span>
      <span
        :if={@supply && @supply.state}
        class={["ml-1 font-sans", @supply.state != "ok" && "font-medium text-crit"]}
      >
        {String.capitalize(String.replace(@supply.state, "_", " "))}
      </span>
      <span :if={!@supply} class="text-fg-muted">—</span>
    </span>
    """
  end

  @boundary_labels %{
    "host_input" => "Host input",
    "supply_input" => "Supply input",
    "supply_output" => "Supply output",
    "outlet" => "Outlet",
    "feed" => "Inlet",
    "leg" => "Leg"
  }

  @quantity_labels %{
    "real_power" => "real power",
    "apparent_power" => "apparent power",
    "current" => "current",
    "voltage" => "voltage",
    "power_factor" => "power factor",
    "state" => "status"
  }

  defp measures_label(%Reading{} = reading) do
    place =
      [
        Map.fetch!(@boundary_labels, reading.boundary),
        reading.component_name,
        reading.leg && String.upcase(reading.leg)
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    window = if reading.window_ms > 0, do: ", #{seconds(reading.window_ms)}s average"
    "#{place} #{Map.fetch!(@quantity_labels, reading.quantity)}#{window}"
  end

  # Whole seconds print without a fraction: 60_000 is "60", 1_500 is "1.5".
  defp seconds(milliseconds) when rem(milliseconds, 1_000) == 0, do: div(milliseconds, 1_000)
  defp seconds(milliseconds), do: milliseconds / 1_000

  defp reading_value(%Reading{validity: "valid", state: state}) when is_binary(state),
    do: String.replace(state, "_", " ")

  # A ratio: rounding to tenths would show 0.96 as 1, and its unit is "1".
  defp reading_value(%Reading{validity: "valid", quantity: "power_factor", value: value}),
    do: value |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp reading_value(%Reading{validity: "valid", value: value, unit: unit}),
    do:
      "#{value |> Decimal.round(1) |> Decimal.normalize() |> Decimal.to_string(:normal)} #{unit}"

  defp reading_value(%Reading{}), do: "—"

  defp mapping_label(%Reading{} = reading) do
    exporter = if reading.origin == "exporter", do: " · exporter"
    "#{reading.mapping_name} v#{reading.mapping_version}#{exporter}"
  end

  defp reading_status(%{eligible?: true}, _now), do: "Current"

  defp reading_status(%{reading: reading}, now) do
    case Reading.ineligibility(reading, now) do
      :stale -> "Stale"
      :missing -> "Missing"
      :failed -> "Failed"
      :invalid -> "Unusable"
      nil -> "Not used"
    end
  end

  # Each port's current input power and status, by port name, from readings
  # that name it.
  defp supplies(entries) do
    entries
    |> Enum.filter(fn %{reading: reading, eligible?: eligible?} ->
      eligible? and reading.component_kind == "power_port" and
        reading.boundary == "supply_input" and
        reading.quantity in ~w(real_power state)
    end)
    |> Enum.group_by(& &1.reading.component_name)
    |> Map.new(fn {name, entries} ->
      draw =
        entries
        |> Enum.map(& &1.reading)
        |> Enum.filter(&(&1.quantity == "real_power"))
        |> Enum.min_by(& &1.window_ms, fn -> nil end)

      state = Enum.find_value(entries, &(&1.reading.quantity == "state" && &1.reading.state))
      {name, %{draw: draw && reading_value(draw), state: state}}
    end)
  end

  defp watts(nil), do: "—"
  defp watts(watts), do: "#{watts} W"
end
