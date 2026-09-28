defmodule RengaWeb.VlanLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Topology

  @status_options [{"Active", "active"}, {"Reserved", "reserved"}, {"Deprecated", "deprecated"}]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "VLANs",
       can_manage?: Inventory.organization_manager?(scope),
       status_options: @status_options,
       vlan_form: vlan_form()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    group_filter = normalize_group_filter(params["group_id"])
    interface_id = blank_to_nil(params["interface_id"])
    interface = interface_id && Inventory.get_interface!(scope, interface_id)

    {:noreply,
     socket
     |> assign(
       group_filter: group_filter,
       interface_id: interface_id,
       interface: interface,
       filter_form: to_form(%{"group_id" => group_filter}, as: :filters)
     )
     |> load_vlans(group_filter)
     |> load_membership(interface)}
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"group_id" => group_id}}, socket) do
    {:noreply,
     push_patch(socket, to: vlans_path(socket, group_id: normalize_group_filter(group_id)))}
  end

  def handle_event("create_vlan", %{"vlan" => params}, socket) do
    scope = socket.assigns.current_scope
    name = String.trim(params["name"] || "")
    vid = parse_vid(params["vid"])

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Name the VLAN before creating it")}

      is_nil(vid) ->
        {:noreply, put_flash(socket, :error, "Enter a VID from 1 to 4094")}

      true ->
        case Topology.create_vlan(
               scope,
               %{lifecycle_state: "active"},
               %{
                 vlan_group_id: blank_to_nil(params["vlan_group_id"]),
                 vid: vid,
                 name: name,
                 status: params["status"] || "active",
                 role: blank_to_nil(params["role"]),
                 description: blank_to_nil(params["description"])
               }
             ) do
          {:ok, vlan} ->
            {:noreply,
             socket
             |> put_flash(:info, "VLAN #{vlan.vid} created")
             |> assign(:vlan_form, vlan_form())
             |> load_vlans(socket.assigns.group_filter)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You are not allowed to manage VLANs")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, first_error(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, mutation_error(reason))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:vlans}>
      <main id="vlans" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Layer 2 inventory
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">VLANs</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Organization VLAN identity grouped by namespace. Desired membership and
              observed membership stay separate from the VLAN itself.
            </p>
          </div>
          <.link
            id="vlans-to-vlan-groups"
            navigate={~p"/ipam/vlan-groups"}
            class="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-base-content/15 bg-base-100 px-4 text-sm font-semibold transition hover:border-orange-500/40 hover:text-orange-600"
          >
            <.icon name="hero-rectangle-group" class="size-4" /> VLAN groups
          </.link>
        </header>

        <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <.form for={@filter_form} id="vlan-filters" phx-change="filter" class="w-full max-w-xs">
            <.input
              field={@filter_form[:group_id]}
              type="select"
              label="Namespace"
              options={@group_filter_options}
              class={input_class()}
            />
          </.form>
          <.link
            :if={@interface}
            id="vlans-clear-interface"
            navigate={~p"/ipam/vlans"}
            class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/55 transition hover:text-orange-600"
          >
            <.icon name="hero-x-mark" class="size-3.5" /> Clear interface filter
          </.link>
        </div>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Visible VLANs" value={@vlan_count} icon="hero-tag" />
          <.summary_card label="Namespaces" value={@group_count} icon="hero-rectangle-group" />
          <.summary_card
            :if={@interface}
            label="Observed memberships"
            value={@current_membership_count}
            icon="hero-signal"
          />
          <.summary_card
            :if={!@interface}
            label="Scope"
            value={scope_filter_label(@group_filter, @groups)}
            icon="hero-globe-alt"
          />
        </section>

        <section
          :if={@interface}
          id="interface-membership"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 class="font-semibold tracking-tight">Interface membership</h2>
              <p class="mt-1 text-sm text-base-content/55">
                <span class="font-mono">{@interface.name}</span> · {@resource.name}
              </p>
            </div>
            <.link
              id="interface-membership-resource"
              navigate={~p"/inventory/resources/#{@resource.id}"}
              class="inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
            >
              Resource detail <.icon name="hero-arrow-right" class="size-3.5" />
            </.link>
          </div>

          <dl class="mt-5 grid gap-3 sm:grid-cols-2">
            <.mode_datum label="Desired mode" mode={@desired_mode} />
            <.mode_datum label="Observed mode" mode={@current_mode} />
          </dl>

          <div class="mt-6 grid gap-6 lg:grid-cols-2">
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                Desired membership
              </h3>
              <ul id="desired-memberships" phx-update="stream" class="mt-3 space-y-2">
                <li
                  id="desired-memberships-empty"
                  class="hidden rounded-xl border border-dashed border-base-content/15 p-4 text-sm text-base-content/45 only:block"
                >
                  No desired VLAN membership recorded.
                </li>
                <li
                  :for={{dom_id, assignment} <- @streams.desired_memberships}
                  id={dom_id}
                  data-tagging-mode={assignment.tagging_mode}
                  class="flex items-center justify-between gap-3 rounded-xl bg-base-200/60 px-4 py-3"
                >
                  <span class="font-mono text-sm">
                    {assignment.vlan.vid} · {assignment.vlan.name}
                  </span>
                  <span class="text-xs font-semibold capitalize text-base-content/55">
                    {assignment.tagging_mode}
                  </span>
                </li>
              </ul>
            </div>

            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                Observed membership
              </h3>
              <ul id="current-memberships" phx-update="stream" class="mt-3 space-y-2">
                <li
                  id="current-memberships-empty"
                  class="hidden rounded-xl border border-dashed border-base-content/15 p-4 text-sm text-base-content/45 only:block"
                >
                  No reconciled membership from source evidence.
                </li>
                <li
                  :for={{dom_id, membership} <- @streams.current_memberships}
                  id={dom_id}
                  data-tagging-mode={membership.tagging_mode}
                  class="flex items-center justify-between gap-3 rounded-xl bg-base-200/60 px-4 py-3"
                >
                  <span class="font-mono text-sm">
                    {membership.vlan.vid} · {membership.vlan.name}
                  </span>
                  <span class="text-xs font-semibold capitalize text-base-content/55">
                    {membership.tagging_mode}
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </section>

        <.form
          :if={@can_manage?}
          for={@vlan_form}
          id="vlan-form"
          phx-submit="create_vlan"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">New VLAN</h2>
              <p class="mt-1 text-xs text-base-content/45">
                A VLAN outside every namespace is allowed; namespace membership only bounds its VID.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55">
              Owner/Admin
            </span>
          </div>
          <div class="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            <.input
              field={@vlan_form[:vlan_group_id]}
              type="select"
              label="Namespace"
              options={@vlan_group_options}
              class={input_class()}
            />
            <.input
              field={@vlan_form[:vid]}
              type="number"
              label="VID"
              min="1"
              max="4094"
              class={input_class()}
            />
            <.input field={@vlan_form[:name]} type="text" label="Name" class={input_class()} />
            <.input
              field={@vlan_form[:status]}
              type="select"
              label="Status"
              options={@status_options}
              class={input_class()}
            />
            <.input
              field={@vlan_form[:role]}
              type="text"
              label="Role (optional)"
              placeholder="management"
              class={input_class()}
            />
            <.input
              field={@vlan_form[:description]}
              type="text"
              label="Description (optional)"
              class={input_class()}
            />
          </div>
          <div class="mt-5 flex justify-end">
            <button
              id="create-vlan"
              type="submit"
              phx-disable-with="Creating…"
              class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
            >
              Create VLAN
            </button>
          </div>
        </.form>

        <section id="vlans-list" phx-update="stream" class="grid gap-3">
          <div
            id="vlans-empty"
            class="hidden rounded-2xl border border-dashed border-base-content/15 bg-base-100 px-6 py-16 text-center only:block"
          >
            <.icon name="hero-tag" class="mx-auto size-9 text-base-content/25" />
            <h2 class="mt-4 font-semibold">No VLANs in this view</h2>
            <p class="mt-1 text-sm text-base-content/50">
              Create a VLAN or change the namespace filter.
            </p>
          </div>

          <article
            :for={{dom_id, vlan} <- @streams.vlans}
            id={dom_id}
            data-vlan-vid={vlan.vid}
            class="flex flex-col gap-4 rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm transition hover:border-orange-500/25 sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="flex min-w-0 items-center gap-4">
              <span class="grid size-12 shrink-0 place-items-center rounded-xl bg-orange-500/10 font-mono text-sm font-semibold text-orange-700 dark:text-orange-400">
                {vlan.vid}
              </span>
              <div class="min-w-0">
                <h2 class="truncate font-semibold tracking-tight">{vlan.name}</h2>
                <p class="mt-1 text-xs text-base-content/45">
                  {vlan_namespace(vlan, @groups)}
                  <span :if={vlan.role}> ·    {vlan.role}</span>
                </p>
                <p :if={vlan.description} class="mt-1 truncate text-xs text-base-content/45">
                  {vlan.description}
                </p>
              </div>
            </div>
            <span class={status_class(vlan.status)}>{vlan.status}</span>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp load_vlans(socket, group_filter) do
    scope = socket.assigns.current_scope
    groups = Topology.list_vlan_groups(scope)
    vlans = Topology.list_vlans(scope, group_scope(group_filter))

    socket
    |> assign(:groups, groups)
    |> assign(:group_count, length(groups))
    |> assign(:vlan_count, length(vlans))
    |> assign(
      :group_filter_options,
      [{"All VLANs", "all"}, {"No group (global)", "global"}] ++
        Enum.map(groups, &{&1.resource.name, &1.id})
    )
    |> assign(
      :vlan_group_options,
      [{"No group (global)", ""}] ++ Enum.map(groups, &{&1.resource.name, &1.id})
    )
    |> stream(:vlans, vlans, dom_id: &"vlan-#{&1.id}", reset: true)
  end

  defp load_membership(socket, nil) do
    socket
    |> assign(:resource, nil)
    |> assign(:desired_mode, nil)
    |> assign(:current_mode, nil)
    |> assign(:current_membership_count, 0)
    |> stream(:desired_memberships, [], reset: true)
    |> stream(:current_memberships, [], reset: true)
  end

  defp load_membership(socket, interface) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_resource!(scope, interface.resource_id)
    desired = Topology.list_desired_interface_vlan_assignments(scope, interface.id)
    current = Topology.list_current_interface_vlan_memberships(scope, interface.id)

    socket
    |> assign(:resource, resource)
    |> assign(:desired_mode, Topology.get_desired_interface_vlan_mode(scope, interface.id))
    |> assign(:current_mode, Topology.get_current_interface_vlan_mode(scope, interface.id))
    |> assign(:current_membership_count, length(current))
    |> stream(:desired_memberships, desired, dom_id: &"desired-membership-#{&1.id}", reset: true)
    |> stream(:current_memberships, current, dom_id: &"current-membership-#{&1.id}", reset: true)
  end

  defp group_scope("all"), do: :all
  defp group_scope("global"), do: nil
  defp group_scope(group_id), do: group_id

  defp normalize_group_filter(value) when value in [nil, ""], do: "all"
  defp normalize_group_filter(value), do: value

  defp vlans_path(socket, overrides) do
    params =
      %{"group_id" => socket.assigns.group_filter, "interface_id" => socket.assigns.interface_id}
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/ipam/vlans?#{params}"
  end

  defp vlan_namespace(%{vlan_group: nil}, _groups), do: "No group (global)"

  defp vlan_namespace(%{vlan_group: group}, _groups),
    do: group.resource.name

  defp scope_filter_label("all", _groups), do: "All"
  defp scope_filter_label("global", _groups), do: "Global"

  defp scope_filter_label(group_id, groups) do
    case Enum.find(groups, &(&1.id == group_id)) do
      nil -> "Namespace"
      group -> group.resource.name
    end
  end

  defp parse_vid(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {vid, ""} -> vid
      _other -> nil
    end
  end

  defp parse_vid(_value), do: nil

  defp vlan_form do
    to_form(
      %{
        "vlan_group_id" => "",
        "vid" => "",
        "name" => "",
        "status" => "active",
        "role" => "",
        "description" => ""
      },
      as: :vlan
    )
  end

  attr :label, :string, required: true
  attr :mode, :any, required: true

  defp mode_datum(assigns) do
    ~H"""
    <div class="rounded-xl bg-base-200/60 px-4 py-3">
      <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/40">{@label}</dt>
      <dd class="mt-1 text-sm font-medium capitalize">{(@mode && @mode.mode) || "Not recorded"}</dd>
    </div>
    """
  end

  defp status_class("active") do
    "shrink-0 self-start rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-emerald-700 dark:text-emerald-400"
  end

  defp status_class(_status) do
    "shrink-0 self-start rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55"
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
      <p class="mt-3 truncate text-2xl font-semibold tracking-tight">{@value}</p>
    </div>
    """
  end

  defp input_class do
    "h-10 w-full rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp mutation_error(:vlan_out_of_range), do: "The VID is outside the selected namespace range"
  defp mutation_error(_reason), do: "The VLAN could not be created"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "The VLAN could not be created"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end
end
