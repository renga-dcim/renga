defmodule RengaWeb.VlanGroupLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Authorization
  alias Renga.DCIM
  alias Renga.Topology

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "VLAN groups",
       can_manage?: Authorization.allowed?(scope, "topology.edit"),
       scope_options: scope_options(scope),
       group_form: group_form()
     )
     |> load_groups()}
  end

  @impl true
  def handle_event("validate_group", %{"vlan_group" => params}, socket) do
    {:noreply, assign(socket, :group_form, to_form(params, as: :vlan_group))}
  end

  @impl true
  def handle_event("create_vlan_group", %{"vlan_group" => params}, socket) do
    scope = socket.assigns.current_scope
    name = String.trim(params["name"] || "")
    {start_vid, end_vid} = parse_range(params)

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Name the VLAN group before creating it")}

      is_nil(start_vid) or is_nil(end_vid) or start_vid > end_vid ->
        {:noreply,
         put_flash(socket, :error, "Enter a VID range from 1 to 4094 with start at or below end")}

      true ->
        {:noreply, create_group(socket, scope, params, name, start_vid, end_vid)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:vlan_groups}
    >
      <main id="vlan-groups" class="mx-auto max-w-6xl space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle">
              Layer 2 inventory
            </p>
            <h1 class="mt-1 text-xl font-semibold tracking-tight text-fg">VLAN groups</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              VLAN-ID namespaces with their allocatable VID ranges. A group scopes VLAN
              identity; it never assigns interface membership.
            </p>
          </div>
          <.button
            :if={@can_manage?}
            id="new-vlan-group"
            variant="primary"
            phx-click={show_overlay("vlan-group-panel")}
          >
            New VLAN group
          </.button>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Groups" value={@group_count} icon="hero-rectangle-group-mini" />
          <.summary_card label="VLANs" value={@vlan_count} icon="hero-tag-mini" />
          <.summary_card
            label="Addressable VIDs"
            value={@vid_capacity}
            icon="hero-hashtag-mini"
          />
        </section>

        <.side_panel
          :if={@can_manage?}
          id="vlan-group-panel"
          title="New VLAN group"
          description="Create a VLAN-ID namespace and its allocatable range."
        >
          <.form
            for={@group_form}
            id="vlan-group-form"
            phx-submit="create_vlan_group"
            phx-change="validate_group"
            class="space-y-1"
          >
            <.input field={@group_form[:name]} type="text" label="Name" />
            <.input
              field={@group_form[:slug]}
              type="text"
              label="Slug (optional)"
              placeholder="derived-from-name"
            />
            <.input
              field={@group_form[:scope]}
              type="select"
              label="Scope"
              options={@scope_options}
            />
            <.input
              field={@group_form[:start_vid]}
              type="number"
              label="First VID"
              min="1"
              max="4094"
            />
            <.input
              field={@group_form[:end_vid]}
              type="number"
              label="Last VID"
              min="1"
              max="4094"
            />
            <.input
              field={@group_form[:description]}
              type="text"
              label="Description (optional)"
            />
          </.form>
          <:footer>
            <.button type="button" phx-click={hide_overlay("vlan-group-panel")}>Cancel</.button>
            <.button
              id="create-vlan-group"
              type="submit"
              form="vlan-group-form"
              variant="primary"
              phx-disable-with="Creating…"
            >
              Create group
            </.button>
          </:footer>
        </.side_panel>

        <section id="vlan-groups-list" phx-update="stream" class="grid gap-3 xl:grid-cols-2">
          <div
            id="vlan-groups-empty"
            class="hidden rounded-lg border border-dashed border-edge bg-surface px-6 py-12 text-center only:block xl:col-span-2"
          >
            <.icon name="hero-tag" class="mx-auto size-8 text-fg-subtle" />
            <h2 class="mt-3 text-sm font-semibold text-fg">No VLAN groups yet</h2>
            <p class="mt-1 text-sm text-fg-muted">
              Create a namespace to bound where VLAN IDs are valid in this organization.
            </p>
          </div>

          <article
            :for={{dom_id, group} <- @streams.vlan_groups}
            id={dom_id}
            data-scope-kind={group.scope_kind}
            class="min-w-0 rounded-lg border border-edge bg-surface px-5 py-4"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 flex-1">
                <h2 class="min-w-0 text-base font-semibold text-fg">
                  <.clip id={"#{dom_id}-name"}>{group.resource.name}</.clip>
                </h2>
                <p class="mt-0.5 break-all font-mono text-xs text-fg-muted">{group.slug}</p>
              </div>
              <.group_status status={group.status} />
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-1.5">
              <span class="inline-flex items-center gap-1 rounded-sm bg-sunken px-1.5 py-0.5 text-[11px] font-medium text-fg-muted">
                <.icon name="hero-globe-alt-mini" class="size-3.5 text-fg-subtle" />
                {scope_label(group)}
              </span>
              <span
                :for={range <- group.vid_ranges}
                data-vid-range={range.id}
                class="rounded-sm bg-sunken px-1.5 py-0.5 font-mono text-[11px] text-fg-muted"
              >
                {range.start_vid}–{range.end_vid}
              </span>
            </div>

            <p :if={group.description} class="mt-3 text-sm text-fg-muted">
              {group.description}
            </p>

            <% utilization = Map.fetch!(@utilization, group.id) %>
            <div class="mt-4 border-t border-line pt-3">
              <div class="flex items-center justify-between text-xs text-fg-muted">
                <span>{utilization.used} of {utilization.capacity} VIDs assigned</span>
                <span class="font-mono tabular-nums">{utilization.percent}%</span>
              </div>
              <div
                class="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-sunken"
                role="progressbar"
                aria-label={"#{group.resource.name} VID usage"}
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={utilization.percent}
              >
                <div
                  class={[
                    "h-full rounded-full",
                    if(utilization.percent >= 90, do: "bg-warn", else: "bg-accent")
                  ]}
                  style={"width: #{utilization.percent}%"}
                />
              </div>
              <.link
                id={"vlan-group-#{group.id}-vlans"}
                navigate={~p"/network/vlans?group_id=#{group.id}"}
                class="mt-3 inline-flex min-h-tap items-center gap-1 rounded-sm text-sm font-medium text-link transition-colors hover:underline focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
              >
                View VLANs <.icon name="hero-arrow-right-mini" class="size-3.5" />
              </.link>
            </div>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end

  # Extracted from handle_event/3 so the handler keeps only input validation;
  # this maps Topology.create_vlan_group/4 outcomes to flashes.
  defp create_group(socket, scope, params, name, start_vid, end_vid) do
    {scope_kind, site_id, location_id} = parse_scope(params["scope"])

    case Topology.create_vlan_group(
           scope,
           %{name: name, lifecycle_state: "active"},
           %{
             slug: blank_to_nil(params["slug"]) || slugify(name),
             scope_kind: scope_kind,
             site_id: site_id,
             location_id: location_id,
             status: "active",
             description: blank_to_nil(params["description"])
           },
           [%{start_vid: start_vid, end_vid: end_vid}]
         ) do
      {:ok, group} ->
        socket
        |> put_flash(:info, "VLAN group #{group.slug} created")
        |> assign(:group_form, group_form())
        |> load_groups()
        |> close_overlay("vlan-group-panel")

      {:error, :forbidden} ->
        put_flash(socket, :error, "You are not allowed to manage VLAN namespaces")

      {:error, %Ecto.Changeset{} = changeset} ->
        put_flash(socket, :error, first_error(changeset))

      {:error, reason} ->
        put_flash(socket, :error, mutation_error(reason))
    end
  end

  defp load_groups(socket) do
    scope = socket.assigns.current_scope
    groups = Topology.list_vlan_groups(scope)
    vlans = Topology.list_vlans(scope)
    assigned = Enum.frequencies_by(vlans, & &1.vlan_group_id)

    utilization =
      Map.new(groups, fn group ->
        capacity = Enum.reduce(group.vid_ranges, 0, &(&2 + &1.end_vid - &1.start_vid + 1))
        used = Map.get(assigned, group.id, 0)

        {group.id,
         %{used: used, capacity: capacity, percent: utilization_percent(used, capacity)}}
      end)

    socket
    |> assign(:group_count, length(groups))
    |> assign(:vlan_count, length(vlans))
    |> assign(:vid_capacity, utilization |> Map.values() |> Enum.map(& &1.capacity) |> Enum.sum())
    |> assign(:utilization, utilization)
    |> stream(:vlan_groups, groups, dom_id: &"vlan-group-#{&1.id}", reset: true)
  end

  defp utilization_percent(_used, 0), do: 0

  defp utilization_percent(used, capacity) do
    min(round(used / capacity * 100), 100)
  end

  defp scope_options(scope) do
    [{"Organization global", "global"}] ++
      Enum.map(DCIM.list_sites(scope), &{"Site · #{&1.resource.name}", "site:#{&1.id}"}) ++
      Enum.map(
        DCIM.list_locations(scope),
        &{"Location · #{&1.resource.name}", "location:#{&1.id}"}
      )
  end

  defp parse_scope("site:" <> site_id), do: {"site", site_id, nil}
  defp parse_scope("location:" <> location_id), do: {"location", nil, location_id}
  defp parse_scope(_scope), do: {"global", nil, nil}

  defp parse_range(params) do
    {parse_integer(params["start_vid"]), parse_integer(params["end_vid"])}
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp group_form do
    to_form(
      %{
        "name" => "",
        "slug" => "",
        "scope" => "global",
        "start_vid" => "1",
        "end_vid" => "4094",
        "description" => ""
      },
      as: :vlan_group
    )
  end

  defp scope_label(%{scope_kind: "site", site: %{resource: %{name: name}}}), do: "Site · #{name}"

  defp scope_label(%{scope_kind: "location", location: %{resource: %{name: name}}}),
    do: "Location · #{name}"

  defp scope_label(_group), do: "Organization global"

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Lifecycle is health-like state, so it takes a status color paired with a
  # shape (filled dot for active, ring otherwise) so it reads in grayscale.
  attr :status, :string, required: true

  defp group_status(assigns) do
    ~H"""
    <span class="inline-flex shrink-0 items-center gap-1.5 text-xs font-medium capitalize text-fg-muted">
      <span
        aria-hidden="true"
        class={[
          "size-2 rounded-full",
          if(@status == "active",
            do: "bg-ok",
            else: "border-[1.5px] border-unknown"
          )
        ]}
      />
      {@status}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-edge bg-surface px-5 py-4">
      <div class="flex items-center gap-1.5 text-fg-subtle">
        <.icon name={@icon} class="size-4" />
        <p class="text-xs font-medium text-fg-muted">{@label}</p>
      </div>
      <p class="mt-2 font-mono text-xl font-semibold tabular-nums tracking-tight text-fg">
        {@value}
      </p>
    </div>
    """
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp mutation_error(:ranges_required), do: "A VLAN group needs at least one VID range"
  defp mutation_error(:invalid_ranges), do: "The VID range is not valid"
  defp mutation_error(_reason), do: "The VLAN group could not be created"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "The VLAN group could not be created"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end
end
