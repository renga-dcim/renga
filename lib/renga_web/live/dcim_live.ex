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
         to_form(%{"name" => "", "height_units" => "42", "width" => "19_inch"}, as: :rack),
       placement_form:
         to_form(
           %{"resource_id" => "", "position" => "", "height_units" => "1", "face" => "front"},
           as: :placement
         )
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
         |> push_navigate(to: ~p"/dcim/sites/#{site.id}")}

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
         |> push_navigate(to: ~p"/dcim/locations/#{location.id}")}

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
         |> push_navigate(to: ~p"/dcim/racks/#{rack.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("place_resource", %{"placement" => params}, socket) do
    rack = socket.assigns.rack

    attrs = %{
      rack_id: rack.id,
      position: blank_to_nil(params["position"]),
      height_units: blank_to_nil(params["height_units"]),
      face: blank_to_nil(params["face"]),
      confirmed: true,
      provenance: %{"confirmed_by_user_id" => socket.assigns.current_scope.user.id}
    }

    case DCIM.put_current_placement(socket.assigns.current_scope, params["resource_id"], attrs) do
      {:ok, _placement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Resource placed")
         |> load_action(:rack, %{"id" => rack.id})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:dcim}>
      <section id="dcim-workspace" class="mx-auto max-w-7xl space-y-6">
        <header class="flex flex-col gap-4 border-b border-base-content/10 pb-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.16em] text-orange-600">DCIM</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">{@page_title}</h1>
            <p class="mt-2 max-w-2xl text-sm text-base-content/55">{@page_description}</p>
          </div>
          <nav
            id="dcim-navigation"
            class="flex gap-1 rounded-lg border border-base-content/10 bg-base-200/50 p-1"
          >
            <.link
              navigate={~p"/dcim/sites"}
              class="rounded-md px-3 py-2 text-xs font-medium transition hover:bg-base-100"
            >
              Sites
            </.link>
            <.link
              navigate={~p"/dcim/racks"}
              class="rounded-md px-3 py-2 text-xs font-medium transition hover:bg-base-100"
            >
              Racks
            </.link>
            <.link
              navigate={~p"/dcim/placement-findings"}
              class="rounded-md px-3 py-2 text-xs font-medium transition hover:bg-base-100"
            >
              Findings
            </.link>
          </nav>
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
          <% :rack -> %>
            <.rack_view {assigns} />
          <% :findings -> %>
            <.findings_view {assigns} />
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
          navigate={~p"/dcim/sites/#{site.id}"}
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
              navigate={~p"/dcim/locations/#{location.id}"}
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
            navigate={~p"/dcim/sites/#{@location.site.id}"}
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
          navigate={~p"/dcim/racks/#{rack.id}"}
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

  defp rack_view(assigns) do
    ~H"""
    <div id="rack-detail" class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_20rem]">
      <div class="rounded-xl border border-base-content/10 bg-base-200/30 p-4">
        <div class="mb-3 grid grid-cols-[3rem_1fr_1fr] gap-2 text-center text-[10px] font-semibold uppercase tracking-wider text-base-content/45">
          <span>Unit</span><span>Front</span><span>Rear</span>
        </div>
        <div id="rack-elevation" class="space-y-1">
          <div
            :for={unit <- @rack_units}
            id={"rack-unit-#{unit}"}
            class="grid min-h-9 grid-cols-[3rem_1fr_1fr] gap-2"
          >
            <span class="grid place-items-center font-mono text-[10px] text-base-content/45">
              {unit}U
            </span>
            <.rack_cell occupancy={Map.get(@front_occupancy, unit)} /><.rack_cell occupancy={
              Map.get(@rear_occupancy, unit)
            } />
          </div>
        </div>
      </div>
      <aside class="space-y-4">
        <div class="rounded-xl border border-base-content/10 p-5">
          <h2 class="font-semibold">Rack details</h2>
          <dl class="mt-4 space-y-3 text-sm">
            <.detail label="Site" value={@rack.site.resource.name} /><.detail
              label="Location"
              value={if @rack.location, do: @rack.location.resource.name, else: "Unassigned"}
            /><.detail
              label="Geometry"
              value={"#{@rack.height_units}U · #{String.replace(@rack.width, "_", " ")}"}
            /><.detail label="Facility ID" value={@rack.facility_id || "Not set"} />
          </dl>
        </div>
        <div id="unplaced-resources" class="rounded-xl border border-base-content/10 p-5">
          <h2 class="font-semibold">Unplaced resources</h2>
          <p class="mt-1 text-xs text-base-content/50">
            {length(@unplaced_resources)} available for placement
          </p>
          <ul class="mt-3 space-y-2">
            <li
              :for={resource <- Enum.take(@unplaced_resources, 8)}
              class="truncate rounded-md bg-base-200/60 px-3 py-2 text-xs"
            >
              {resource.name}
            </li>
          </ul>
        </div>
        <.form
          :if={@can_manage? and @unplaced_resources != []}
          for={@placement_form}
          id="rack-placement-form"
          phx-submit="place_resource"
          class="space-y-3 rounded-xl border border-base-content/10 bg-base-200/40 p-5"
        >
          <div>
            <h2 class="font-semibold">Place resource</h2>
            <p class="mt-1 text-xs text-base-content/50">
              Leave the position blank for zero-U or non-consuming equipment.
            </p>
          </div>
          <.input
            field={@placement_form[:resource_id]}
            type="select"
            label="Resource"
            prompt="Select resource"
            options={Enum.map(@unplaced_resources, &{&1.name, &1.id})}
            required
          />
          <div class="grid grid-cols-2 gap-2">
            <.input field={@placement_form[:position]} type="number" label="Starting U" min="1" />
            <.input field={@placement_form[:height_units]} type="number" label="Height" min="1" />
          </div>
          <.input
            field={@placement_form[:face]}
            type="select"
            label="Face"
            options={[{"Front", "front"}, {"Rear", "rear"}, {"Full depth", "full"}]}
          />
          <button
            id="place-resource"
            type="submit"
            phx-disable-with="Placing…"
            class="w-full rounded-lg bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
          >
            Confirm placement
          </button>
        </.form>
      </aside>
    </div>
    """
  end

  defp findings_view(assigns) do
    ~H"""
    <div id="placement-findings" class="space-y-3">
      <div
        :if={@findings == []}
        id="findings-empty"
        class="rounded-xl border border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/50"
      >
        No open placement findings.
      </div>
      <article
        :for={finding <- @findings}
        id={"finding-#{finding.id}"}
        class="flex gap-4 rounded-xl border border-amber-500/20 bg-amber-500/[0.04] p-5"
      >
        <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-amber-500/10 text-amber-700">
          <.icon name="hero-exclamation-triangle" class="size-5" />
        </span>
        <div>
          <p class="text-xs font-semibold uppercase tracking-wider text-amber-700">
            {String.replace(finding.kind, "_", " ")}
          </p>
          <h2 class="mt-1 font-semibold">{finding.resource.name}</h2>
          <p class="mt-1 text-sm text-base-content/60">{finding.message}</p>
        </div>
      </article>
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

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail(assigns) do
    ~H"""
    <div class="flex justify-between gap-3">
      <dt class="text-base-content/45">{@label}</dt>
      <dd class="text-right font-medium capitalize">{@value}</dd>
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
              do: ~p"/dcim/racks/#{record.id}",
              else: ~p"/dcim/locations/#{record.id}"
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

  attr :occupancy, :any, default: nil

  defp rack_cell(assigns) do
    ~H"""
    <div class={[
      "grid place-items-center rounded border px-2 py-1 text-center text-xs",
      if(@occupancy,
        do: "border-orange-500/30 bg-orange-500/10 font-medium text-orange-800",
        else: "border-base-content/10 bg-base-100 text-base-content/45"
      )
    ]}>
      <%= if @occupancy do %>
        <span class="max-w-full truncate">{@occupancy.current_placement.resource.name}</span>
        <span class="max-w-full truncate text-[9px] font-normal opacity-70">
          {placement_status(@occupancy.current_placement)}
        </span>
      <% else %>
        Available
      <% end %>
    </div>
    """
  end

  defp placement_status(placement) do
    state = String.capitalize(placement.resource.lifecycle_state)

    cond do
      placement.confirmed ->
        "#{state} · Confirmed"

      placement.evidence_stale? ->
        "#{state} · Stale evidence"

      placement.evidence_observed_at ->
        observed_on = placement.evidence_observed_at |> DateTime.to_date() |> Date.to_iso8601()
        "#{state} · Observed #{observed_on}"

      true ->
        "#{state} · Inferred"
    end
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

  defp load_action(socket, :rack, %{"id" => id}) do
    rack = DCIM.get_rack!(socket.assigns.current_scope, id)
    {front, rear} = occupancy_maps(rack.occupancies)

    assign(socket,
      rack: rack,
      rack_units: Enum.to_list(rack.height_units..1//-1),
      front_occupancy: front,
      rear_occupancy: rear,
      unplaced_resources: DCIM.list_unplaced_resources(socket.assigns.current_scope),
      page_title: rack.resource.name,
      page_description: "Front and rear occupancy with overlap-safe rack units."
    )
  end

  defp load_action(socket, :findings, _params),
    do:
      assign(socket,
        findings: DCIM.list_placement_findings(socket.assigns.current_scope),
        page_title: "Placement findings",
        page_description: "Unresolved, conflicting, or blocked physical placement assertions."
      )

  defp occupancy_maps(occupancies) do
    Enum.reduce(occupancies, {%{}, %{}}, fn occupancy, {front, rear} ->
      units = occupancy.units.lower..(occupancy.units.upper - 1)

      target =
        Enum.reduce(
          units,
          if(occupancy.face == "front", do: front, else: rear),
          &Map.put(&2, &1, occupancy)
        )

      if occupancy.face == "front", do: {target, rear}, else: {front, target}
    end)
  end

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
end
