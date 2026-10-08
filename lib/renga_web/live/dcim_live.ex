defmodule RengaWeb.DcimLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       can_manage?: Renga.Inventory.organization_manager?(socket.assigns.current_scope),
       site_form: to_form(%{"name" => "", "slug" => "", "time_zone" => "Etc/UTC"}, as: :site),
       location_form: to_form(%{"name" => "", "kind" => ""}, as: :location),
       rack_form:
         to_form(%{"name" => "", "height_units" => "42", "width" => "19_inch"}, as: :rack)
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
      <section id="dcim-workspace" class="mx-auto max-w-7xl space-y-6">
        <header class="flex flex-col gap-4 border-b border-base-content/10 pb-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.16em] text-orange-600">
              Places
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">{@page_title}</h1>
            <p class="mt-2 max-w-2xl text-sm text-base-content/55">{@page_description}</p>
          </div>
        </header>

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
      </section>
    </Layouts.app>
    """
  end

  defp sites_view(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div id="sites" class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <div
          :if={@sites == []}
          id="sites-empty"
          class="col-span-full rounded-xl border border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/50"
        >
          No sites yet. Add the first facility to begin placing inventory.
        </div>
        <.link
          :for={site <- @sites}
          id={"site-#{site.id}"}
          navigate={~p"/places/sites/#{site.id}"}
          class="group rounded-xl border border-base-content/10 bg-base-100 p-5 transition hover:-translate-y-0.5 hover:border-orange-500/40 hover:shadow-lg"
        >
          <div class="flex items-start justify-between">
            <span class="grid size-10 place-items-center rounded-lg bg-orange-500/10 text-orange-600">
              <.icon name="hero-building-office-2" class="size-5" />
            </span>
            <span class="rounded-full bg-emerald-500/10 px-2 py-1 text-[10px] font-semibold uppercase text-emerald-700">
              {site.status}
            </span>
          </div>
          <h2 class="mt-5 font-semibold">{site.resource.name}</h2>
          <p class="mt-1 font-mono text-xs text-base-content/45">{site.slug}</p>
        </.link>
      </div>
      <.form
        :if={@can_manage?}
        for={@site_form}
        id="new-site-form"
        phx-submit="create_site"
        class="h-fit space-y-4 rounded-xl border border-base-content/10 bg-base-200/40 p-5"
      >
        <div>
          <h2 class="font-semibold">Add site</h2>
          <p class="mt-1 text-xs text-base-content/50">Create a campus, datacenter, or office.</p>
        </div>
        <.input field={@site_form[:name]} label="Name" required />
        <.input field={@site_form[:slug]} label="Slug" required />
        <.input field={@site_form[:time_zone]} label="Time zone" />
        <button
          id="create-site"
          type="submit"
          phx-disable-with="Creating…"
          class="w-full rounded-lg bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
        >
          Create site
        </button>
      </.form>
    </div>
    """
  end

  defp site_view(assigns) do
    ~H"""
    <div id="site-detail" class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div class="space-y-6">
        <div class="rounded-xl border border-base-content/10 p-5">
          <div class="flex flex-wrap gap-8">
            <.metric label="Locations" value={length(@site.locations)} /><.metric
              label="Racks"
              value={length(@site.racks)}
            /><.metric label="Time zone" value={@site.time_zone || "Not set"} />
          </div>
          <p
            :if={@site.physical_address}
            class="mt-5 border-t border-base-content/10 pt-4 text-sm text-base-content/60"
          >
            {@site.physical_address}
          </p>
        </div>
        <div>
          <h2 class="mb-3 font-semibold">Locations</h2>
          <div id="site-locations" class="space-y-2">
            <p
              :if={@site.locations == []}
              class="rounded-lg border border-dashed border-base-content/15 p-6 text-sm text-base-content/50"
            >
              No locations in this site.
            </p>
            <.link
              :for={location <- @site.locations}
              id={"location-#{location.id}"}
              navigate={~p"/places/locations/#{location.id}"}
              class="flex items-center gap-3 rounded-lg border border-base-content/10 p-3 transition hover:border-orange-500/30"
            >
              <.icon name="hero-map-pin" class="size-4 text-orange-600" />
              <span class="font-medium">
                {location.resource.name}
              </span>
              <span class="ml-auto text-xs text-base-content/45">{location.kind || "Location"}</span>
            </.link>
          </div>
        </div>
      </div>
      <.form
        :if={@can_manage?}
        for={@location_form}
        id="new-location-form"
        phx-submit="create_location"
        class="h-fit space-y-4 rounded-xl border border-base-content/10 bg-base-200/40 p-5"
      >
        <div>
          <h2 class="font-semibold">Add location</h2>
          <p class="mt-1 text-xs text-base-content/50">
            Rooms, floors, rows, cages, and zones can be nested.
          </p>
        </div>
        <.input field={@location_form[:name]} label="Name" required />
        <.input field={@location_form[:kind]} label="Kind" placeholder="Room, floor, row…" />
        <.input
          field={@location_form[:parent_id]}
          type="select"
          label="Parent"
          prompt="Top level"
          options={Enum.map(@site.locations, &{&1.resource.name, &1.id})}
        />
        <button
          id="create-location"
          type="submit"
          class="w-full rounded-lg bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
        >
          Create location
        </button>
      </.form>
    </div>
    """
  end

  defp location_view(assigns) do
    ~H"""
    <div id="location-detail" class="space-y-6">
      <div class="rounded-xl border border-base-content/10 p-5">
        <p class="text-sm text-base-content/55">
          Site
          <.link
            navigate={~p"/places/sites/#{@location.site.id}"}
            class="font-medium text-orange-600 hover:underline"
          >
            {@location.site.resource.name}
          </.link>
        </p>
        <p :if={@location.parent} class="mt-2 text-sm text-base-content/55">
          Inside {@location.parent.resource.name}
        </p>
      </div>
      <div class="grid gap-6 md:grid-cols-2">
        <.collection title="Child locations" records={@location.children} path={:location} /><.collection
          title="Racks"
          records={@location.racks}
          path={:rack}
        />
      </div>
    </div>
    """
  end

  defp racks_view(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div id="racks" class="space-y-2">
        <p
          :if={@racks == []}
          id="racks-empty"
          class="rounded-xl border border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/50"
        >
          No racks yet.
        </p>
        <.link
          :for={rack <- @racks}
          id={"rack-#{rack.id}"}
          navigate={~p"/places/racks/#{rack.id}"}
          class="flex items-center gap-4 rounded-xl border border-base-content/10 p-4 transition hover:border-orange-500/30"
        >
          <span class="grid size-10 place-items-center rounded-lg bg-base-200">
            <.icon name="hero-server" class="size-5" />
          </span>
          <div>
            <h2 class="font-semibold">{rack.resource.name}</h2>
            <p class="mt-1 text-xs text-base-content/45">
              {rack.site.resource.name}{if rack.location, do: " · #{rack.location.resource.name}"}
            </p>
          </div>
          <span class="ml-auto font-mono text-xs text-base-content/50">{rack.height_units}U</span>
        </.link>
      </div>
      <.form
        :if={@can_manage? and @sites != []}
        for={@rack_form}
        id="new-rack-form"
        phx-submit="create_rack"
        class="h-fit space-y-4 rounded-xl border border-base-content/10 bg-base-200/40 p-5"
      >
        <div>
          <h2 class="font-semibold">Add rack</h2>
          <p class="mt-1 text-xs text-base-content/50">Rack geometry is enforced during placement.</p>
        </div>
        <.input field={@rack_form[:name]} label="Name" required /><.input
          field={@rack_form[:site_id]}
          type="select"
          label="Site"
          prompt="Select site"
          options={Enum.map(@sites, &{&1.resource.name, &1.id})}
          required
        /><.input
          field={@rack_form[:location_id]}
          type="select"
          label="Location (optional)"
          prompt="No location"
          options={Enum.map(@locations, &{"#{&1.site.resource.name} / #{&1.resource.name}", &1.id})}
        /><.input field={@rack_form[:facility_id]} label="Facility ID" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@rack_form[:height_units]} type="number" label="Height (U)" min="1" required /><.input
            field={@rack_form[:width]}
            type="select"
            label="Width"
            options={[
              {"19 inch", "19_inch"},
              {"21 inch", "21_inch"},
              {"23 inch", "23_inch"},
              {"Custom", "custom"}
            ]}
          />
        </div>
        <button
          id="create-rack"
          type="submit"
          class="w-full rounded-lg bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
        >
          Create rack
        </button>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metric(assigns) do
    ~H"""
    <div>
      <p class="text-[10px] font-semibold uppercase tracking-wider text-base-content/40">{@label}</p>
      <p class="mt-1 text-lg font-semibold">{@value}</p>
    </div>
    """
  end

  attr :records, :list, required: true
  attr :title, :string, required: true
  attr :path, :atom, required: true

  defp collection(assigns) do
    ~H"""
    <section class="rounded-xl border border-base-content/10 p-5">
      <h2 class="font-semibold">{@title}</h2>
      <p :if={@records == []} class="mt-4 text-sm text-base-content/45">None</p>
      <div class="mt-3 space-y-2">
        <.link
          :for={record <- @records}
          navigate={
            if(@path == :rack,
              do: ~p"/places/racks/#{record.id}",
              else: ~p"/places/locations/#{record.id}"
            )
          }
          class="block rounded-md bg-base-200/60 px-3 py-2 text-sm font-medium transition hover:bg-base-200"
        >
          {record.resource.name}
        </.link>
      </div>
    </section>
    """
  end

  defp load_action(socket, :sites, _params),
    do:
      assign(socket,
        sites: DCIM.list_sites(socket.assigns.current_scope),
        page_title: "Sites",
        page_description: "Facilities and geographic containment for physical inventory."
      )

  defp load_action(socket, :site, %{"id" => id}) do
    site = DCIM.get_site!(socket.assigns.current_scope, id)

    assign(socket,
      site: site,
      page_title: site.resource.name,
      page_description: "Locations and racks inside this facility."
    )
  end

  defp load_action(socket, :location, %{"id" => id}) do
    location = DCIM.get_location!(socket.assigns.current_scope, id)

    assign(socket,
      location: location,
      page_title: location.resource.name,
      page_description: "Nested physical containment and rack inventory."
    )
  end

  defp load_action(socket, :racks, _params),
    do:
      assign(socket,
        racks: DCIM.list_racks(socket.assigns.current_scope),
        sites: DCIM.list_sites(socket.assigns.current_scope),
        locations: DCIM.list_locations(socket.assigns.current_scope),
        page_title: "Racks",
        page_description: "Geometry-aware rack inventory and elevations."
      )

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
