defmodule RengaWeb.VlanGroupLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Topology

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "VLAN groups",
       can_manage?: Inventory.organization_manager?(scope),
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
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:vlan_groups}>
      <main id="vlan-groups" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Layer 2 inventory
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">VLAN groups</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              VLAN-ID namespaces with their allocatable VID ranges. A group scopes VLAN
              identity; it never assigns interface membership.
            </p>
          </div>
          <.link
            id="vlan-groups-to-vlans"
            navigate={~p"/network/vlans"}
            class="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-base-content/15 bg-base-100 px-4 text-sm font-semibold transition hover:border-orange-500/40 hover:text-orange-600"
          >
            <.icon name="hero-tag" class="size-4" /> Browse VLANs
          </.link>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Groups" value={@group_count} icon="hero-rectangle-group" />
          <.summary_card label="VLANs" value={@vlan_count} icon="hero-tag" />
          <.summary_card label="Addressable VIDs" value={@vid_capacity} icon="hero-hashtag" />
        </section>

        <.form
          :if={@can_manage?}
          for={@group_form}
          id="vlan-group-form"
          phx-submit="create_vlan_group"
          phx-change="validate_group"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">New VLAN group</h2>
              <p class="mt-1 text-xs text-base-content/55">
                Creating a namespace changes shared VLAN identity, so only owners and admins may submit it.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55">
              Owner/Admin
            </span>
          </div>
          <div class="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            <.input field={@group_form[:name]} type="text" label="Name" class={input_class()} />
            <.input
              field={@group_form[:slug]}
              type="text"
              label="Slug (optional)"
              placeholder="derived-from-name"
              class={input_class()}
            />
            <.input
              field={@group_form[:scope]}
              type="select"
              label="Scope"
              options={@scope_options}
              class={input_class()}
            />
            <.input
              field={@group_form[:start_vid]}
              type="number"
              label="First VID"
              min="1"
              max="4094"
              class={input_class()}
            />
            <.input
              field={@group_form[:end_vid]}
              type="number"
              label="Last VID"
              min="1"
              max="4094"
              class={input_class()}
            />
            <.input
              field={@group_form[:description]}
              type="text"
              label="Description (optional)"
              class={input_class()}
            />
          </div>
          <div class="mt-5 flex justify-end">
            <button
              id="create-vlan-group"
              type="submit"
              phx-disable-with="Creating…"
              class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
            >
              Create group
            </button>
          </div>
        </.form>

        <section id="vlan-groups-list" phx-update="stream" class="grid gap-4 xl:grid-cols-2">
          <div
            id="vlan-groups-empty"
            class="hidden rounded-2xl border border-dashed border-base-content/15 bg-base-100 px-6 py-16 text-center only:block xl:col-span-2"
          >
            <.icon name="hero-tag" class="mx-auto size-9 text-base-content/25" />
            <h2 class="mt-4 font-semibold">No VLAN groups yet</h2>
            <p class="mt-1 text-sm text-base-content/50">
              Create a namespace to bound where VLAN IDs are valid in this organization.
            </p>
          </div>

          <article
            :for={{dom_id, group} <- @streams.vlan_groups}
            id={dom_id}
            data-scope-kind={group.scope_kind}
            class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm transition hover:border-orange-500/25 hover:shadow-md"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <h2 class="truncate text-lg font-semibold tracking-tight">
                  {group.resource.name}
                </h2>
                <p class="mt-1 font-mono text-xs text-base-content/55">{group.slug}</p>
              </div>
              <span class={status_class(group.status)}>{group.status}</span>
            </div>

            <div class="mt-4 flex flex-wrap items-center gap-2">
              <span class="inline-flex items-center gap-1.5 rounded-full bg-base-200 px-2.5 py-1 text-xs font-medium text-base-content/60">
                <.icon name="hero-globe-alt" class="size-3.5" /> {scope_label(group)}
              </span>
              <span
                :for={range <- group.vid_ranges}
                data-vid-range={range.id}
                class="rounded-lg bg-base-200 px-2 py-1 font-mono text-xs text-base-content/60"
              >
                {range.start_vid}–{range.end_vid}
              </span>
            </div>

            <p :if={group.description} class="mt-4 text-sm text-base-content/55">
              {group.description}
            </p>

            <% utilization = Map.fetch!(@utilization, group.id) %>
            <div class="mt-5 border-t border-base-content/10 pt-4">
              <div class="flex items-center justify-between text-xs text-base-content/55">
                <span>{utilization.used} of {utilization.capacity} VIDs assigned</span>
                <span class="font-mono">{utilization.percent}%</span>
              </div>
              <div class="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-base-content/10">
                <div
                  class={[
                    "h-full rounded-full",
                    utilization.percent >= 90 && "bg-rose-500",
                    utilization.percent < 90 && "bg-orange-500"
                  ]}
                  style={"width: #{utilization.percent}%"}
                />
              </div>
              <.link
                id={"vlan-group-#{group.id}-vlans"}
                navigate={~p"/network/vlans?group_id=#{group.id}"}
                class="mt-4 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
              >
                View VLANs <.icon name="hero-arrow-right" class="size-3.5" />
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

  defp status_class("active") do
    "shrink-0 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-emerald-700 dark:text-emerald-400"
  end

  defp status_class(_status) do
    "shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55"
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm">
      <div class="flex items-center gap-2 text-base-content/45">
        <.icon name={@icon} class="size-4" />
        <p class="text-xs font-semibold uppercase tracking-wider">{@label}</p>
      </div>
      <p class="mt-3 text-2xl font-semibold tracking-tight">{@value}</p>
    </div>
    """
  end

  defp input_class do
    "h-10 w-full rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
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
