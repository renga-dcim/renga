defmodule RengaWeb.ResourcePowerLive do
  @moduledoc """
  A device's Power tab (RFD 10 phase 2): the power ports where power comes
  in and the outlets where it goes out, as its hardware type defines them.

  A port shows its maximum draw and allocated draw in W. The allocation
  defaults from the catalog template; owners and admins can override it per
  port in a side panel, and clearing the override restores the default.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents

  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Power
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
       allocation_form: allocation_form(nil)
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
              row_click={if @can_manage?, do: &edit_port/1}
            >
              <:col :let={port} label="Port">
                <span class="font-mono">{port.name}</span>
                <span :if={port.label} class="ml-2 text-fg-muted">{port.label}</span>
              </:col>
              <:col :let={port} label="Connector" class="text-fg-muted">{port.connector || "—"}</:col>
              <:col :let={port} label="Maximum" class="text-right font-mono tabular-nums">
                {watts(port.maximum_draw_w)}
              </:col>
              <:col :let={port} label="Allocated" class="text-right">
                <span class="font-mono tabular-nums">{watts(Port.allocated_draw_w(port))}</span>
                <span
                  :if={port.allocated_draw_w}
                  class="ml-1 text-xs text-fg-muted"
                  title="Set on this device instead of from its hardware type"
                >
                  set here
                </span>
              </:col>
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
            </.table>
          </section>
        </div>
      </.resource_frame>

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
    </Layouts.app>
    """
  end

  defp edit_port(port),
    do: "edit_port" |> JS.push(value: %{id: port.id}) |> show_overlay("allocation-panel")

  defp load_endpoints(socket) do
    %{ports: ports, outlets: outlets} =
      Power.list_device_endpoints(socket.assigns.current_scope, socket.assigns.resource.id)

    allocations = Enum.map(ports, &Port.allocated_draw_w/1)
    unallocated = Enum.count(allocations, &is_nil/1)

    assign(socket,
      ports: ports,
      outlets: outlets,
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
