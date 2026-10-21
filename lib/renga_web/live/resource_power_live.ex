defmodule RengaWeb.ResourcePowerLive do
  @moduledoc """
  A device's Power tab (RFD 10 phase 2): the power ports where power comes
  in and the outlets where it goes out, as its hardware type defines them.

  A port shows its maximum draw and allocated draw in W. The allocation
  defaults from the catalog template; owners and admins can override it per
  port in a side panel, and clearing the override restores the default.

  Each port shows its power path: the outlets and PDUs it passes through on
  the way to a panel feed, or where that path stops. Each outlet shows what
  it powers. Owners and admins record a connection or unplug
  one; both are confirmed power cable claims (RFD 10 phase 2b).
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
       can_manage?: Inventory.organization_manager?(scope),
       editing_port: nil,
       allocation_form: allocation_form(nil),
       connecting_port: nil,
       connect_form: to_form(%{"target" => ""}, as: :connection),
       connect_error: nil,
       connect_options: [],
       selected_path: nil
     )
     |> load_endpoints()}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_endpoints(socket)}

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
       connect_options: connect_options(socket)
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
          Cables.connect(socket.assigns.current_scope, Map.put(attrs, :power_port_id, port.id))
      end

    case result do
      {:ok, _assertion} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{port.name} #{result_label}")
         |> assign(connecting_port: nil, connect_error: nil)
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

  def handle_event("save_allocation", %{"allocation" => params}, socket) do
    watts = params |> Map.get("allocated_draw_w", "") |> String.trim()
    attrs = %{allocated_draw_w: if(watts == "", do: nil, else: watts)}

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
              <:action :let={port} :if={@can_manage?}>
                <div class="flex justify-end gap-2">
                  <.button
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
                    :if={@cables_by_port[port.id]}
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
              <:action :let={cable} :if={@can_manage?}>
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
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("allocation-panel")}>Cancel</.button>
            <.button id="save-allocation" variant="primary" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="connect-panel"
        title={connection_title(@connecting_port, @cables_by_port)}
      >
        <.form for={@connect_form} id="connect-form" phx-submit="save_connection" class="space-y-1">
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

  defp connection_error(:power_endpoint_retired),
    do: "That port or outlet is no longer part of its hardware type"

  defp connection_error(_reason), do: "Choose an outlet or feed to connect"

  defp edit_port(port),
    do: "edit_port" |> JS.push(value: %{id: port.id}) |> show_overlay("allocation-panel")

  defp show_path(path),
    do: "show_path" |> JS.push(value: %{id: path.port.id}) |> show_overlay("path-panel")

  defp load_endpoints(socket) do
    %{ports: ports, outlets: outlets} =
      Power.list_device_endpoints(socket.assigns.current_scope, socket.assigns.resource.id)

    cables =
      Cables.list_cables(socket.assigns.current_scope, resource_ids: [socket.assigns.resource.id])

    paths = Paths.for_ports(socket.assigns.current_scope, ports)
    selected_path_id = socket.assigns.selected_path && socket.assigns.selected_path.port.id
    allocations = Enum.map(ports, &Port.allocated_draw_w/1)
    unallocated = Enum.count(allocations, &is_nil/1)

    assign(socket,
      ports: ports,
      outlets: outlets,
      cables_by_port: Map.new(cables, &{&1.power_port_id, &1}),
      paths_by_port: Map.new(paths, &{&1.port.id, &1}),
      selected_path: Enum.find(paths, &(&1.port.id == selected_path_id)),
      cables_by_outlet:
        for(cable <- cables, cable.power_outlet_id, into: %{}, do: {cable.power_outlet_id, cable}),
      retired_cables: Enum.filter(cables, &retired_for_resource?(&1, socket.assigns.resource.id)),
      unallocated: unallocated,
      allocated_total: if(unallocated == 0, do: Enum.sum(allocations))
    )
  end

  defp allocation_form(nil), do: to_form(%{"allocated_draw_w" => ""}, as: :allocation)

  defp allocation_form(%Port{} = port),
    do: to_form(%{"allocated_draw_w" => port.allocated_draw_w || ""}, as: :allocation)

  defp watts(nil), do: "—"
  defp watts(watts), do: "#{watts} W"
end
