defmodule RengaWeb.DcimLive do
  @moduledoc """
  Places (RFD 8): the site, location, and rack hierarchy that ends in a rack
  elevation (`RengaWeb.RackLive`).

  Sites and racks are lists in the shared list grammar; a site and a
  location are object pages with a breadcrumb up the hierarchy, their
  locations as an indented tree, and their racks with how full each face
  is. Owners and admins add sites, locations, and racks in side panels;
  everyone else reads.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM

  @widths [
    {"19 inch", "19_inch"},
    {"21 inch", "21_inch"},
    {"23 inch", "23_inch"},
    {"Custom", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       can_manage?: Renga.Inventory.organization_manager?(socket.assigns.current_scope),
       site_form: to_form(%{"name" => "", "slug" => "", "time_zone" => "Etc/UTC"}, as: :site),
       location_form: to_form(%{"name" => "", "kind" => "", "parent_id" => ""}, as: :location),
       rack_form: rack_form(%{}),
       widths: @widths
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("create_site", %{"site" => params}, socket) do
    case DCIM.create_site(
           socket.assigns.current_scope,
           %{name: params["name"], lifecycle_state: "active"},
           %{
             slug: params["slug"],
             status: "active",
             time_zone: blank_to_nil(params["time_zone"])
           }
         ) do
      {:ok, site} ->
        {:noreply,
         socket
         |> put_flash(:info, "Site created")
         |> push_navigate(to: ~p"/places/sites/#{site.id}")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage physical inventory")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}
    end
  end

  def handle_event("create_location", %{"location" => params}, socket) do
    site = socket.assigns.site

    attrs = %{
      site_id: site.id,
      parent_id: blank_to_nil(params["parent_id"]),
      kind: blank_to_nil(params["kind"]),
      status: "active"
    }

    case DCIM.create_location(
           socket.assigns.current_scope,
           %{name: params["name"], lifecycle_state: "active"},
           attrs
         ) do
      {:ok, location} ->
        {:noreply,
         socket
         |> put_flash(:info, "Location created")
         |> push_navigate(to: ~p"/places/locations/#{location.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  # The rack form's locations follow its site.
  def handle_event("rack_change", %{"rack" => params}, socket) do
    {:noreply,
     assign(socket, rack_form: rack_form(params), rack_locations: rack_locations(socket, params))}
  end

  def handle_event("create_rack", %{"rack" => params}, socket) do
    attrs = %{
      site_id: params["site_id"],
      location_id: blank_to_nil(params["location_id"]),
      status: "active",
      height_units: params["height_units"],
      width: params["width"],
      starting_unit: "bottom",
      facility_id: blank_to_nil(params["facility_id"])
    }

    case DCIM.create_rack(
           socket.assigns.current_scope,
           %{name: params["name"], lifecycle_state: "active"},
           attrs
         ) do
      {:ok, rack} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rack created")
         |> push_navigate(to: ~p"/places/racks/#{rack.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={dcim_nav(@live_action)}
    >
      <div id="dcim-workspace">
        <%= case @live_action do %>
          <% :sites -> %>
            <.sites_view {assigns} />
          <% :site -> %>
            <.site_view {assigns} />
          <% :location -> %>
            <.location_view {assigns} />
          <% :racks -> %>
            <.racks_view {assigns} />
        <% end %>
      </div>

      <.side_panel :if={@can_manage?} id="site-panel" title="New site">
        <.form for={@site_form} id="new-site-form" phx-submit="create_site" class="space-y-1">
          <.input field={@site_form[:name]} label="Name" required autocomplete="off" />
          <.input field={@site_form[:slug]} label="Slug" required autocomplete="off" />
          <.input field={@site_form[:time_zone]} label="Time zone" />
          <.panel_actions panel="site-panel" id="create-site" label="Create site" />
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_manage? and @live_action == :site}
        id="location-panel"
        title="New location"
      >
        <.form
          for={@location_form}
          id="new-location-form"
          phx-submit="create_location"
          class="space-y-1"
        >
          <.input field={@location_form[:name]} label="Name" required autocomplete="off" />
          <.input field={@location_form[:kind]} label="Kind" placeholder="Room, floor, row, cage…" />
          <.input
            field={@location_form[:parent_id]}
            type="select"
            label="Inside"
            prompt="The site itself"
            options={
              Enum.map(@location_tree, fn {location, depth} ->
                {indent(location.resource.name, depth), location.id}
              end)
            }
          />
          <.panel_actions panel="location-panel" id="create-location" label="Create location" />
        </.form>
      </.side_panel>

      <.side_panel :if={@can_manage? and @rack_sites != []} id="rack-panel" title="New rack">
        <.form
          for={@rack_form}
          id="new-rack-form"
          phx-change="rack_change"
          phx-submit="create_rack"
          class="space-y-1"
        >
          <.input field={@rack_form[:name]} label="Name" required autocomplete="off" />
          <.input
            field={@rack_form[:site_id]}
            type="select"
            label="Site"
            prompt="Choose a site"
            options={Enum.map(@rack_sites, &{&1.resource.name, &1.id})}
            required
          />
          <.input
            :if={@rack_locations != []}
            field={@rack_form[:location_id]}
            type="select"
            label="Location (optional)"
            prompt="No location"
            options={Enum.map(@rack_locations, &{&1.resource.name, &1.id})}
          />
          <.input field={@rack_form[:facility_id]} label="Facility ID" autocomplete="off" />
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@rack_form[:height_units]}
              type="number"
              label="Height (U)"
              min="1"
              required
            />
            <.input field={@rack_form[:width]} type="select" label="Width" options={@widths} />
          </div>
          <.panel_actions panel="rack-panel" id="create-rack" label="Create rack" />
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp sites_view(assigns) do
    ~H"""
    <section class="mx-auto max-w-5xl space-y-4 px-6 py-6">
      <.list_header title="Sites" description="Facilities, and the locations and racks inside them.">
        <.button
          :if={@can_manage?}
          id="new-site"
          variant="primary"
          phx-click={show_overlay("site-panel")}
        >
          New site
        </.button>
      </.list_header>

      <.table
        id="sites"
        rows={@sites}
        row_id={&"site-#{&1.id}"}
        row_click={&JS.navigate(~p"/places/sites/#{&1.id}")}
        class="rounded-lg border border-edge bg-surface"
      >
        <:col :let={site} label="Site" class="py-2">
          <.link
            navigate={~p"/places/sites/#{site.id}"}
            class="block font-medium text-fg hover:underline"
          >
            {site.resource.name}
          </.link>
          <span class="block font-mono text-xs text-fg-muted">{site.slug}</span>
        </:col>
        <:col :let={site} label="Locations" class="text-right font-mono tabular-nums">
          {count(@site_counts, site.id, :locations)}
        </:col>
        <:col :let={site} label="Racks" class="text-right font-mono tabular-nums">
          {count(@site_counts, site.id, :racks)}
        </:col>
        <:col :let={site} label="Status" class="text-fg-muted">
          {String.capitalize(site.status)}
        </:col>
        <:empty>
          No sites yet.
          <span :if={@can_manage?}>Add the first facility to start placing devices.</span>
        </:empty>
      </.table>
    </section>
    """
  end

  defp site_view(assigns) do
    ~H"""
    <.object_page id="site-detail" title={@site.resource.name} subtitle={@site.slug}>
      <:breadcrumb>
        <.link navigate={~p"/places"} class="hover:text-fg">Places</.link>
      </:breadcrumb>
      <:icon><.icon name="hero-building-office-2" class="size-5" /></:icon>
      <:actions :if={@can_manage?}>
        <.button id="new-location" size="sm" phx-click={show_overlay("location-panel")}>
          New location
        </.button>
        <.button
          id="new-rack"
          size="sm"
          variant="primary"
          phx-click={
            JS.push("rack_change", value: %{rack: %{site_id: @site.id}})
            |> show_overlay("rack-panel")
          }
        >
          New rack
        </.button>
      </:actions>

      <div class="space-y-6">
        <.location_tree id="site-locations" tree={@location_tree} />
        <.racks_table
          id="site-racks"
          racks={@site.racks}
          fill={@fill}
          empty="No racks at this site yet."
        />
      </div>

      <:aside>
        <.properties id="site-properties" title="Site">
          <:item label="Status">{String.capitalize(@site.status)}</:item>
          <:item label="Time zone" blank={is_nil(@site.time_zone)}>{@site.time_zone}</:item>
          <:item label="Address" blank={is_nil(@site.physical_address)}>
            {@site.physical_address}
          </:item>
          <:item label="Locations">{length(@site.locations)}</:item>
          <:item label="Racks">{length(@site.racks)}</:item>
        </.properties>
      </:aside>
    </.object_page>
    """
  end

  defp location_view(assigns) do
    ~H"""
    <.object_page id="location-detail" title={@location.resource.name} subtitle={@location.kind}>
      <:breadcrumb>
        <.link navigate={~p"/places"} class="hover:text-fg">Places</.link>
        <span aria-hidden="true">/</span>
        <.link navigate={~p"/places/sites/#{@location.site.id}"} class="hover:text-fg">
          {@location.site.resource.name}
        </.link>
        <%= for ancestor <- @ancestors do %>
          <span aria-hidden="true">/</span>
          <.link navigate={~p"/places/locations/#{ancestor.id}"} class="hover:text-fg">
            {ancestor.resource.name}
          </.link>
        <% end %>
      </:breadcrumb>
      <:icon><.icon name="hero-map-pin" class="size-5" /></:icon>
      <:actions :if={@can_manage?}>
        <.button
          id="new-rack"
          size="sm"
          variant="primary"
          phx-click={
            JS.push("rack_change",
              value: %{rack: %{site_id: @location.site.id, location_id: @location.id}}
            )
            |> show_overlay("rack-panel")
          }
        >
          New rack here
        </.button>
      </:actions>

      <div class="space-y-6">
        <section :if={@location.children != []} id="location-children" class="space-y-2">
          <h2 class="text-xs font-medium text-fg-muted">Inside {@location.resource.name}</h2>
          <ul class="divide-y divide-edge rounded-lg border border-edge bg-surface">
            <li :for={child <- @location.children} id={"location-#{child.id}"}>
              <.link
                navigate={~p"/places/locations/#{child.id}"}
                class="flex min-h-row items-center gap-2 px-3 text-sm transition-colors hover:bg-sunken"
              >
                <.icon name="hero-map-pin-mini" class="size-4 text-fg-subtle" />
                <span class="font-medium text-fg">{child.resource.name}</span>
                <span :if={child.kind} class="ml-auto text-xs text-fg-muted">{child.kind}</span>
              </.link>
            </li>
          </ul>
        </section>
        <.racks_table
          id="location-racks"
          racks={@location.racks}
          fill={@fill}
          empty="No racks here yet."
        />
      </div>

      <:aside>
        <.properties id="location-properties" title="Location">
          <:item label="Site">{@location.site.resource.name}</:item>
          <:item label="Inside" blank={is_nil(@location.parent)} placeholder="The site itself">
            {@location.parent && @location.parent.resource.name}
          </:item>
          <:item label="Kind" blank={is_nil(@location.kind)}>{@location.kind}</:item>
          <:item label="Status">{String.capitalize(@location.status)}</:item>
        </.properties>
      </:aside>
    </.object_page>
    """
  end

  defp racks_view(assigns) do
    ~H"""
    <section class="mx-auto max-w-5xl space-y-4 px-6 py-6">
      <.list_header title="Racks" description="Every rack, where it is, and how full each face is.">
        <.button
          :if={@can_manage? and @rack_sites != []}
          id="new-rack"
          variant="primary"
          phx-click={show_overlay("rack-panel")}
        >
          New rack
        </.button>
      </.list_header>
      <.racks_table id="racks" racks={@racks} fill={@fill} show_place empty="No racks yet." />
    </section>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :inner_block

  defp list_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 class="text-xl font-semibold tracking-tight text-fg">{@title}</h1>
        <p class="mt-1 text-sm text-fg-muted">{@description}</p>
      </div>
      {render_slot(@inner_block)}
    </header>
    """
  end

  attr :id, :string, required: true
  attr :tree, :list, required: true

  defp location_tree(assigns) do
    ~H"""
    <section id={@id} class="space-y-2">
      <h2 class="text-xs font-medium text-fg-muted">Locations</h2>
      <p :if={@tree == []} id={"#{@id}-empty"} class="text-sm text-fg-muted">No locations yet.</p>
      <ul :if={@tree != []} class="divide-y divide-edge rounded-lg border border-edge bg-surface">
        <li :for={{location, depth} <- @tree} id={"location-#{location.id}"} data-depth={depth}>
          <.link
            navigate={~p"/places/locations/#{location.id}"}
            class="flex min-h-row items-center gap-2 pr-3 text-sm transition-colors hover:bg-sunken"
            style={"padding-left: #{0.75 + depth * 1.25}rem"}
          >
            <.icon name="hero-map-pin-mini" class="size-4 text-fg-subtle" />
            <span class="font-medium text-fg">{location.resource.name}</span>
            <span :if={location.kind} class="ml-auto text-xs text-fg-muted">{location.kind}</span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :racks, :list, required: true
  attr :fill, :map, required: true
  attr :empty, :string, required: true
  attr :show_place, :boolean, default: false

  defp racks_table(assigns) do
    ~H"""
    <section class="space-y-2">
      <h2 :if={!@show_place} class="text-xs font-medium text-fg-muted">Racks</h2>
      <.table
        id={@id}
        rows={@racks}
        row_id={&"rack-#{&1.id}"}
        row_click={&JS.navigate(~p"/places/racks/#{&1.id}")}
        class="rounded-lg border border-edge bg-surface"
      >
        <:col :let={rack} label="Rack" class="py-2">
          <.link
            navigate={~p"/places/racks/#{rack.id}"}
            class="block font-medium text-fg hover:underline"
          >
            {rack.resource.name}
          </.link>
          <span :if={rack.facility_id} class="block font-mono text-xs text-fg-muted">
            {rack.facility_id}
          </span>
        </:col>
        <:col :let={rack} :if={@show_place} label="Where" class="text-fg-muted">
          {rack.site.resource.name}{if rack.location, do: " / #{rack.location.resource.name}"}
        </:col>
        <:col :let={rack} label="Front">
          <.fill_bar used={fill(@fill, rack, :front)} height={rack.height_units} />
        </:col>
        <:col :let={rack} label="Rear">
          <.fill_bar used={fill(@fill, rack, :rear)} height={rack.height_units} />
        </:col>
        <:empty>{@empty}</:empty>
      </.table>
    </section>
    """
  end

  attr :used, :integer, required: true
  attr :height, :integer, required: true

  defp fill_bar(assigns) do
    assigns = assign(assigns, :percent, round(assigns.used * 100 / max(assigns.height, 1)))

    ~H"""
    <span class="flex items-center gap-2" data-used={@used}>
      <span class="block h-1.5 w-16 overflow-hidden rounded-full bg-sunken" aria-hidden="true">
        <span class="block h-full rounded-full bg-accent" style={"width: #{@percent}%"}></span>
      </span>
      <span class="font-mono text-xs tabular-nums text-fg-muted">{@used}/{@height}U</span>
    </span>
    """
  end

  attr :panel, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp panel_actions(assigns) do
    ~H"""
    <div class="mt-4 flex justify-end gap-2">
      <.button type="button" phx-click={hide_overlay(@panel)}>Cancel</.button>
      <.button id={@id} variant="primary" phx-disable-with="Creating…">{@label}</.button>
    </div>
    """
  end

  defp load_action(socket, :sites, _params) do
    scope = socket.assigns.current_scope
    sites = DCIM.list_sites(scope)

    socket
    |> assign(sites: sites, site_counts: DCIM.site_counts(scope), page_title: "Sites")
    |> assign_rack_choices(sites)
  end

  defp load_action(socket, :site, %{"id" => id}) do
    scope = socket.assigns.current_scope
    site = DCIM.get_site!(scope, id)

    socket
    |> assign(
      site: site,
      location_tree: tree(site.locations),
      fill: DCIM.rack_fill(scope, Enum.map(site.racks, & &1.id)),
      page_title: site.resource.name
    )
    |> assign_rack_choices([site])
  end

  defp load_action(socket, :location, %{"id" => id}) do
    scope = socket.assigns.current_scope
    location = DCIM.get_location!(scope, id)
    site_locations = DCIM.list_locations(scope, location.site_id)

    socket
    |> assign(
      location: location,
      ancestors: ancestors(location, site_locations),
      fill: DCIM.rack_fill(scope, Enum.map(location.racks, & &1.id)),
      page_title: location.resource.name
    )
    |> assign_rack_choices([location.site])
  end

  defp load_action(socket, :racks, _params) do
    scope = socket.assigns.current_scope
    racks = DCIM.list_racks(scope)

    socket
    |> assign(
      racks: racks,
      fill: DCIM.rack_fill(scope, Enum.map(racks, & &1.id)),
      page_title: "Racks"
    )
    |> assign_rack_choices(DCIM.list_sites(scope))
  end

  # Sites the rack form offers, and the locations of the chosen one.
  defp assign_rack_choices(socket, sites) do
    socket = assign(socket, rack_sites: sites)
    assign(socket, rack_locations: rack_locations(socket, socket.assigns.rack_form.params))
  end

  defp rack_locations(socket, %{"site_id" => site_id}) when site_id not in [nil, ""] do
    case Ecto.UUID.cast(site_id) do
      {:ok, id} -> DCIM.list_locations(socket.assigns.current_scope, id)
      :error -> []
    end
  end

  defp rack_locations(_socket, _params), do: []

  defp rack_form(params) do
    %{
      "name" => "",
      "site_id" => "",
      "location_id" => "",
      "facility_id" => "",
      "height_units" => "42",
      "width" => "19_inch"
    }
    |> Map.merge(params)
    |> to_form(as: :rack)
  end

  # Locations in display order with their nesting depth, parents first.
  defp tree(locations) do
    children = Enum.group_by(locations, & &1.parent_id)
    ids = MapSet.new(locations, & &1.id)

    locations
    |> Enum.filter(&(is_nil(&1.parent_id) or not MapSet.member?(ids, &1.parent_id)))
    |> sort_by_name()
    |> Enum.flat_map(&subtree(&1, children, 0))
  end

  defp subtree(location, children, depth) do
    nested =
      children
      |> Map.get(location.id, [])
      |> sort_by_name()
      |> Enum.flat_map(&subtree(&1, children, depth + 1))

    [{location, depth} | nested]
  end

  defp sort_by_name(locations), do: Enum.sort_by(locations, &String.downcase(&1.resource.name))

  # Parents from the outermost down, stopping at a missing parent or a cycle.
  defp ancestors(location, site_locations) do
    by_id = Map.new(site_locations, &{&1.id, &1})

    {location.parent_id, MapSet.new([location.id])}
    |> Stream.unfold(&next_ancestor(&1, by_id))
    |> Enum.reverse()
  end

  defp next_ancestor({nil, _seen}, _by_id), do: nil

  defp next_ancestor({id, seen}, by_id) do
    case {Map.get(by_id, id), MapSet.member?(seen, id)} do
      {nil, _seen?} -> nil
      {_parent, true} -> nil
      {parent, false} -> {parent, {parent.parent_id, MapSet.put(seen, id)}}
    end
  end

  defp indent(name, 0), do: name
  defp indent(name, depth), do: String.duplicate("— ", depth) <> name

  defp count(counts, site_id, key), do: counts |> Map.get(site_id, %{}) |> Map.get(key, 0)

  defp fill(fill, rack, face), do: fill |> Map.get(rack.id, %{}) |> Map.get(face, 0)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
  defp mutation_error(:forbidden), do: "You are not allowed to manage physical inventory"
  defp mutation_error(_reason), do: "Physical inventory could not be updated"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "Physical inventory could not be updated"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end

  # The area tabs come from RengaWeb.Navigation.
  defp dcim_nav(:racks), do: :racks
  defp dcim_nav(_action), do: :sites
end
