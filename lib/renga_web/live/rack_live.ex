defmodule RengaWeb.RackLive do
  @moduledoc """
  A rack (RFD 8, "Places"): its elevation with front and rear side by side,
  the devices seen here but recorded elsewhere, and the devices that can be
  placed here.

  On a phone the elevation shows one face at a time (`?face=rear`), and a
  device is placed by choosing a free unit from a list in the placement
  panel; on larger screens free units are also targets to click. Owners and
  admins place devices; everyone else reads the rack.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.ElevationComponents

  alias Renga.DCIM
  alias Renga.DCIM.Elevation
  alias Renga.Inventory
  alias Renga.Inventory.Changes

  @reload_after_ms 400

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       rack_id: id,
       can_place?: Inventory.organization_manager?(scope),
       reload_timer: nil
     )
     |> load_elevation()
     |> assign_place(%{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    face = if params["face"] == "rear", do: "rear", else: "front"
    {:noreply, assign(socket, :face, face)}
  end

  @impl true
  def handle_event("open_place", params, socket) do
    {:noreply, assign_place(socket, Map.take(params, ~w(resource_id position face)))}
  end

  def handle_event("place_change", %{"place" => params}, socket) do
    {:noreply, assign_place(socket, params)}
  end

  def handle_event("place", %{"place" => params}, socket) do
    %{current_scope: scope, elevation: elevation} = socket.assigns

    with {:ok, resource} <- placeable_resource(elevation, params["resource_id"]),
         {:ok, placement} <-
           DCIM.place_in_rack(
             scope,
             resource.id,
             elevation.rack.id,
             params["position"],
             params["face"]
           ) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "#{resource.name} placed at #{unit_range(placement.position, placement.height_units)}"
       )
       |> close_overlay("place-panel")
       |> load_elevation()
       |> assign_place(%{})}
    else
      {:error, reason} -> {:noreply, place_error(socket, reason)}
    end
  end

  def handle_event("place_observed", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.elevation.observed, &(&1.resource.id == id)) do
      nil -> {:noreply, load_elevation(socket)}
      ghost -> {:noreply, place_observed(socket, ghost)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_elevation() |> refresh_place()}
  end

  defp place_observed(socket, ghost) do
    %{current_scope: scope, elevation: elevation} = socket.assigns

    case DCIM.place_observed(scope, ghost.resource.id, elevation.rack.id) do
      {:ok, %{position: nil}} ->
        socket
        |> put_flash(:info, "#{ghost.resource.name} is in this rack; choose its unit")
        |> load_elevation()

      {:ok, placement} ->
        socket
        |> put_flash(
          :info,
          "#{ghost.resource.name} placed at #{unit_range(placement.position, placement.height_units)}"
        )
        |> load_elevation()

      {:error, reason} ->
        place_error(socket, reason)
    end
  end

  defp load_elevation(socket) do
    elevation = DCIM.rack_elevation(socket.assigns.current_scope, socket.assigns.rack_id)
    assign(socket, elevation: elevation, page_title: elevation.rack.resource.name)
  end

  ## Placement panel

  # The panel's form: which device, which face, and a free unit that fits
  # the device's height on that face. Changing the device or face keeps
  # the unit only while it still fits.
  defp assign_place(socket, params) do
    elevation = socket.assigns.elevation
    candidates = candidates(elevation)

    candidate =
      Enum.find(candidates, &(&1.resource.id == params["resource_id"])) || List.first(candidates)

    resource_id = candidate && candidate.resource.id
    face = if params["face"] in ~w(front rear full), do: params["face"], else: "front"
    height = if candidate, do: candidate.height, else: 1
    positions = if resource_id, do: Elevation.free_positions(elevation, height, face), else: []
    position = fitting_position(params["position"], positions)

    socket
    |> assign(:place_positions, positions)
    |> assign(:place_height, height)
    |> assign(:place_options, candidate_options(elevation))
    |> assign(
      :place_form,
      to_form(
        %{
          "resource_id" => resource_id,
          "face" => face,
          "position" => position && to_string(position)
        },
        as: :place
      )
    )
  end

  defp refresh_place(socket), do: assign_place(socket, socket.assigns.place_form.params)

  defp candidates(elevation), do: elevation.in_rack ++ elevation.at_location ++ elevation.unplaced

  defp fitting_position(nil, [first | _rest]), do: first
  defp fitting_position(nil, []), do: nil

  defp fitting_position(value, positions) do
    case Integer.parse(to_string(value)) do
      {position, ""} -> if position in positions, do: position, else: List.first(positions)
      _invalid -> List.first(positions)
    end
  end

  # Grouped select options, nearest devices first.
  defp candidate_options(elevation) do
    location = elevation.rack.location || elevation.rack.site

    [
      {"In this rack, no unit yet", elevation.in_rack},
      {"At #{location.resource.name}", elevation.at_location},
      {"Not placed anywhere", elevation.unplaced}
    ]
    |> Enum.reject(fn {_label, items} -> items == [] end)
    |> Enum.map(fn {label, items} ->
      {label, Enum.map(items, &{"#{&1.resource.name} (#{&1.height}U)", &1.resource.id})}
    end)
  end

  defp placeable_resource(elevation, id) do
    case Enum.find(candidates(elevation), &(&1.resource.id == id)) do
      nil -> {:error, :not_placeable}
      candidate -> {:ok, candidate.resource}
    end
  end

  defp place_error(socket, %Ecto.Changeset{}),
    do:
      socket
      |> put_flash(:error, "Those units are taken; choose another")
      |> load_elevation()
      |> refresh_place()

  defp place_error(socket, :rack_position_out_of_bounds),
    do: put_flash(socket, :error, "The device does not fit there; choose a lower unit")

  defp place_error(socket, :forbidden),
    do: put_flash(socket, :error, "Placing devices requires the owner or admin role")

  defp place_error(socket, _reason),
    do:
      socket
      |> put_flash(:error, "That changed elsewhere; try again")
      |> load_elevation()
      |> refresh_place()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:racks}
    >
      <.object_page
        id="rack"
        title={@elevation.rack.resource.name}
        subtitle={rack_subtitle(@elevation.rack)}
      >
        <:breadcrumb>
          <.link navigate={~p"/places"} class="hover:text-fg">Places</.link>
          <span aria-hidden="true">/</span>
          <.link navigate={~p"/places/sites/#{@elevation.rack.site.id}"} class="hover:text-fg">
            {@elevation.rack.site.resource.name}
          </.link>
          <%= if @elevation.rack.location do %>
            <span aria-hidden="true">/</span>
            <.link
              navigate={~p"/places/locations/#{@elevation.rack.location.id}"}
              class="hover:text-fg"
            >
              {@elevation.rack.location.resource.name}
            </.link>
          <% end %>
        </:breadcrumb>
        <:icon><.icon name="hero-server-stack" class="size-5" /></:icon>
        <:actions>
          <.button
            :if={@can_place? and @place_options != []}
            id="place-device"
            size="sm"
            variant="primary"
            phx-click={JS.push("open_place", value: %{}) |> show_overlay("place-panel")}
          >
            Place a device
          </.button>
        </:actions>

        <div class="space-y-3">
          <.segmented id="rack-face-toggle" label="Rack face" class="lg:hidden">
            <:option
              id="rack-face-front"
              patch={~p"/places/racks/#{@rack_id}"}
              active={@face == "front"}
            >
              Front
            </:option>
            <:option
              id="rack-face-rear"
              patch={~p"/places/racks/#{@rack_id}?face=rear"}
              active={@face == "rear"}
            >
              Rear
            </:option>
          </.segmented>

          <div id="rack-elevation" class="grid gap-4 lg:grid-cols-2">
            <.rack_face
              id="rack-face-front-view"
              face="front"
              elevation={@elevation}
              can_place?={@can_place?}
              class={@face != "front" && "hidden lg:block"}
            />
            <.rack_face
              id="rack-face-rear-view"
              face="rear"
              elevation={@elevation}
              can_place?={@can_place?}
              class={@face != "rear" && "hidden lg:block"}
            />
          </div>
        </div>

        <:aside>
          <section :if={@elevation.observed != []} id="observed" class="space-y-2">
            <div>
              <h2 class="text-xs font-medium text-fg-muted">Seen here, recorded elsewhere</h2>
              <p class="text-xs text-fg-subtle">
                Placing one here records it where it was seen.
              </p>
            </div>
            <ul class="space-y-2">
              <.observed_item
                :for={ghost <- @elevation.observed}
                ghost={ghost}
                can_place?={@can_place?}
              />
            </ul>
          </section>

          <section id="placeable" class="space-y-3">
            <h2 class="text-xs font-medium text-fg-muted">Can go in this rack</h2>
            <.placeable_group
              id="placeable-in-rack"
              title="In this rack, no unit yet"
              items={@elevation.in_rack}
              can_place?={@can_place?}
            />
            <.placeable_group
              id="placeable-at-location"
              title={"At #{(@elevation.rack.location || @elevation.rack.site).resource.name}"}
              items={@elevation.at_location}
              can_place?={@can_place?}
            />
            <.placeable_group
              id="placeable-unplaced"
              title="Not placed anywhere"
              items={@elevation.unplaced}
              total={@elevation.unplaced_total}
              can_place?={@can_place?}
            />
            <p
              :if={@place_options == []}
              id="placeable-empty"
              class="text-sm text-fg-muted"
            >
              Nothing is waiting for a place.
            </p>
          </section>

          <.properties id="rack-properties" title="Rack">
            <:item label="Site">{@elevation.rack.site.resource.name}</:item>
            <:item label="Location" blank={is_nil(@elevation.rack.location)} placeholder="None">
              {@elevation.rack.location && @elevation.rack.location.resource.name}
            </:item>
            <:item label="Height">{@elevation.rack.height_units}U</:item>
            <:item label="Width">{String.replace(@elevation.rack.width, "_", " ")}</:item>
            <:item label="Facility ID" blank={is_nil(@elevation.rack.facility_id)}>
              {@elevation.rack.facility_id}
            </:item>
          </.properties>
        </:aside>
      </.object_page>

      <.side_panel :if={@can_place?} id="place-panel" title="Place a device">
        <.form
          for={@place_form}
          id="place-form"
          phx-change="place_change"
          phx-submit="place"
          class="space-y-1"
        >
          <.input
            id="place-resource"
            field={@place_form[:resource_id]}
            type="select"
            label="Device"
            options={@place_options}
          />
          <.input
            id="place-face"
            field={@place_form[:face]}
            type="select"
            label="Face"
            options={[{"Front", "front"}, {"Rear", "rear"}, {"Full depth", "full"}]}
          />
          <.input
            :if={@place_positions != []}
            id="place-unit"
            field={@place_form[:position]}
            type="select"
            label={"Unit (#{@place_height}U device)"}
            options={Enum.map(@place_positions, &{unit_range(&1, @place_height), &1})}
          />
          <p :if={@place_positions == []} id="place-no-room" class="py-2 text-sm text-fg-muted">
            <%= if @place_options == [] do %>
              No devices are waiting for a place.
            <% else %>
              No {@place_height}U gap is free on this face.
            <% end %>
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("place-panel")}>Cancel</.button>
            <.button
              id="place-save"
              variant="primary"
              disabled={@place_positions == []}
              phx-disable-with="Placing…"
            >
              Place
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :total, :integer, default: nil
  attr :can_place?, :boolean, default: false

  defp placeable_group(assigns) do
    ~H"""
    <div :if={@items != []} id={@id} class="space-y-1">
      <h3 class="flex items-baseline justify-between text-xs text-fg-muted">
        {@title}
        <span :if={@total && @total > length(@items)} class="font-mono text-[11px]">
          {length(@items)} of {@total}
        </span>
      </h3>
      <ul class="divide-y divide-edge rounded-md border border-edge bg-surface">
        <li
          :for={item <- @items}
          id={"placeable-#{item.resource.id}"}
          data-height={item.height}
          class="flex min-h-tap items-center gap-2 px-2.5 py-1 text-sm sm:min-h-8"
        >
          <.link
            navigate={~p"/inventory/#{item.resource}"}
            class="min-w-0 flex-1 truncate hover:underline"
          >
            {item.resource.name}
          </.link>
          <span class="font-mono text-[11px] text-fg-subtle">{item.height}U</span>
          <button
            :if={@can_place?}
            id={"placeable-#{item.resource.id}-place"}
            type="button"
            phx-click={
              JS.push("open_place", value: %{resource_id: item.resource.id})
              |> show_overlay("place-panel")
            }
            class="min-h-tap cursor-pointer text-xs text-link hover:underline sm:min-h-0"
          >
            Place
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp rack_subtitle(rack) do
    ["#{rack.height_units}U", String.replace(rack.width, "_", " "), rack.facility_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
