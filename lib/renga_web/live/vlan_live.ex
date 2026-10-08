defmodule RengaWeb.VlanLive do
  @moduledoc """
  The VLAN list (RFD 8, "VLANs"): VLAN groups with an ID-range usage strip,
  then VLANs with their planned and observed member counts and linked
  prefixes. A VLAN opens its detail page, where membership is compared per
  interface and prefixes are linked.

  `?group_id=` filters by group (`global` for VLANs outside every group).
  `?interface_id=` shows one interface's desired and observed membership,
  which is where resource pages link to.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Topology
  alias Renga.Topology.VlanUsage
  alias RengaWeb.VlanComponents

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

  def handle_event("validate_vlan", %{"vlan" => params}, socket) do
    {:noreply, assign(socket, :vlan_form, to_form(params, as: :vlan))}
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
        {:noreply, create_vlan(socket, scope, params, name, vid)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:vlans}
    >
      <section id="vlans" class="mx-auto max-w-6xl space-y-6 px-6 py-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">VLANs</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              VLAN groups bound which IDs a VLAN may use. Planned membership is what operators
              intend; observed membership is what collectors report.
            </p>
          </div>
          <.button
            :if={@can_manage?}
            id="new-vlan"
            variant="primary"
            phx-click={show_overlay("vlan-panel")}
          >
            New VLAN
          </.button>
        </header>

        <.interface_membership
          :if={@interface}
          interface={@interface}
          resource={@resource}
          desired_mode={@desired_mode}
          current_mode={@current_mode}
          desired_membership_count={@desired_membership_count}
          current_membership_count={@current_membership_count}
          streams={@streams}
        />

        <section :if={@groups != []} id="vlan-groups-usage" class="space-y-2">
          <h2 class="text-xs font-medium text-fg-muted">
            VLAN groups <span class="font-mono tabular-nums">{length(@groups)}</span>
          </h2>
          <ul class="divide-y divide-edge rounded-lg border border-edge bg-surface">
            <li :for={{group, usage} <- @group_usage} id={"vlan-group-#{group.id}"}>
              <.link
                patch={vlans_path(@group_filter, @interface_id, group_id: group.id)}
                aria-current={@group_filter == group.id && "true"}
                class={[
                  "grid min-h-tap items-center gap-x-4 gap-y-1.5 px-3 py-2.5 transition-colors sm:grid-cols-[12rem_minmax(0,1fr)_9rem]",
                  if(@group_filter == group.id, do: "bg-accent-tint", else: "hover:bg-sunken")
                ]}
              >
                <span class="min-w-0">
                  <span class="block truncate text-sm font-medium text-fg">
                    {group.resource.name}
                  </span>
                  <span class="block font-mono text-[11px] text-fg-muted">
                    {VlanComponents.ranges_label(group)}
                  </span>
                </span>
                <VlanComponents.usage_strip id={"vlan-group-#{group.id}-strip"} usage={usage} />
                <span class="font-mono text-xs tabular-nums text-fg-muted sm:text-right">
                  {usage.used} of {usage.capacity} IDs
                </span>
              </.link>
            </li>
          </ul>
        </section>

        <section id="vlans-table" class="space-y-2">
          <div class="flex flex-wrap items-end justify-between gap-3">
            <h2 class="text-xs font-medium text-fg-muted">
              {filter_label(@group_filter, @groups)}
              <span class="font-mono tabular-nums">{@vlan_count}</span>
            </h2>
            <div class="flex items-end gap-3">
              <.link
                :if={@interface}
                id="vlans-clear-interface"
                navigate={~p"/network/vlans"}
                class="text-xs text-fg-muted hover:text-fg"
              >
                Clear interface filter
              </.link>
              <.form for={@filter_form} id="vlan-filters" phx-change="filter" class="w-56">
                <.input
                  field={@filter_form[:group_id]}
                  type="select"
                  label="Group"
                  options={@group_filter_options}
                />
              </.form>
            </div>
          </div>

          <.table
            id="vlans-list"
            rows={@streams.vlans}
            row_navigate={fn {_id, vlan} -> ~p"/network/vlans/#{vlan.id}" end}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={{_id, vlan}} label="VID" class="w-0">
              <span class="font-mono font-medium tabular-nums" data-vlan-vid={vlan.vid}>
                {vlan.vid}
              </span>
            </:col>
            <:col :let={{_id, vlan}} label="Name">
              <span class="block font-medium text-fg">{vlan.name}</span>
              <span :if={vlan.role} class="block text-xs text-fg-muted">{vlan.role}</span>
            </:col>
            <:col :let={{_id, vlan}} label="Group" class="hidden text-fg-muted sm:table-cell">
              {vlan_group_name(vlan)}
            </:col>
            <:col :let={{_id, vlan}} label="Status" class="hidden text-fg-muted md:table-cell">
              {String.capitalize(vlan.status)}
            </:col>
            <:col :let={{_id, vlan}} label="Planned" class="text-right font-mono tabular-nums">
              <span id={"vlan-#{vlan.id}-planned"}>
                {member_count(@member_counts, vlan, :planned)}
              </span>
            </:col>
            <:col :let={{_id, vlan}} label="Observed" class="text-right font-mono tabular-nums">
              <span id={"vlan-#{vlan.id}-observed"}>
                {member_count(@member_counts, vlan, :observed)}
              </span>
            </:col>
            <:col :let={{_id, vlan}} label="Prefixes" class="hidden lg:table-cell">
              <ul
                :if={Map.has_key?(@prefixes_by_vlan, vlan.id)}
                id={"vlan-#{vlan.id}-prefixes"}
                class="flex flex-wrap gap-1"
              >
                <li
                  :for={prefix <- Map.get(@prefixes_by_vlan, vlan.id)}
                  id={"vlan-#{vlan.id}-prefix-#{prefix.id}"}
                  data-prefix-cidr={VlanComponents.prefix_cidr(prefix)}
                  title={prefix.resource.name}
                  class="rounded border border-edge bg-sunken px-1.5 font-mono text-[11px] text-fg"
                >
                  {VlanComponents.prefix_cidr(prefix)}
                </li>
              </ul>
            </:col>
            <:empty>No VLANs in this view. Create one or choose another group.</:empty>
          </.table>
        </section>
      </section>

      <.side_panel
        :if={@can_manage?}
        id="vlan-panel"
        title="New VLAN"
        description="A VLAN outside every group is allowed; a group only bounds its ID."
      >
        <.form
          for={@vlan_form}
          id="vlan-form"
          phx-submit="create_vlan"
          phx-change="validate_vlan"
          class="space-y-1"
        >
          <.input
            field={@vlan_form[:vlan_group_id]}
            type="select"
            label="Group"
            options={@vlan_group_options}
          />
          <.input field={@vlan_form[:vid]} type="number" label="VID" min="1" max="4094" />
          <.input field={@vlan_form[:name]} type="text" label="Name" />
          <.input
            field={@vlan_form[:status]}
            type="select"
            label="Status"
            options={@status_options}
          />
          <.input
            field={@vlan_form[:role]}
            type="text"
            label="Role (optional)"
            placeholder="management"
          />
          <.input field={@vlan_form[:description]} type="text" label="Description (optional)" />
        </.form>
        <:footer>
          <.button
            id="create-vlan"
            variant="primary"
            form="vlan-form"
            phx-disable-with="Creating…"
          >
            Create VLAN
          </.button>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :interface, :any, required: true
  attr :resource, :any, required: true
  attr :desired_mode, :any, required: true
  attr :current_mode, :any, required: true
  attr :desired_membership_count, :integer, required: true
  attr :current_membership_count, :integer, required: true
  attr :streams, :any, required: true

  defp interface_membership(assigns) do
    ~H"""
    <section id="interface-membership" class="space-y-4 rounded-lg border border-edge bg-surface p-4">
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-sm font-semibold text-fg">Interface membership</h2>
          <p class="text-sm text-fg-muted">
            <span class="font-mono text-fg">{@interface.name}</span> · {@resource.name}
          </p>
        </div>
        <.link
          id="interface-membership-resource"
          navigate={~p"/inventory/#{@resource.id}"}
          class="inline-flex items-center gap-1 text-sm text-link hover:underline"
        >
          Resource detail <.icon name="hero-arrow-right-mini" class="size-4" />
        </.link>
      </div>

      <dl class="grid gap-3 sm:grid-cols-2">
        <.mode_datum
          id="interface-membership-desired-mode"
          label="Desired mode"
          mode={@desired_mode}
          memberships={@desired_membership_count}
          missing_value="Not recorded"
          membership_missing_value="Not recorded"
          without_mode_note="Desired membership is recorded; no desired mode was set."
        />
        <.mode_datum
          id="interface-membership-observed-mode"
          label="Observed mode"
          mode={@current_mode}
          memberships={@current_membership_count}
          missing_value="Not recorded"
          membership_missing_value="Unavailable"
          without_mode_note="Membership was observed; no reconciled port mode is available."
        />
      </dl>

      <div class="grid gap-4 lg:grid-cols-2">
        <.membership_list
          id="desired-memberships"
          title="Desired membership"
          rows={@streams.desired_memberships}
          empty="No desired VLAN membership recorded."
        />
        <.membership_list
          id="current-memberships"
          title="Observed membership"
          rows={@streams.current_memberships}
          empty="No reconciled membership from source evidence."
        />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :any, required: true
  attr :empty, :string, required: true

  defp membership_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <h3 class="text-xs font-medium text-fg-muted">{@title}</h3>
      <ul id={@id} phx-update="stream" class="divide-y divide-edge rounded-md border border-edge">
        <li id={"#{@id}-empty"} class="hidden px-3 py-3 text-sm text-fg-muted only:block">
          {@empty}
        </li>
        <li
          :for={{dom_id, membership} <- @rows}
          id={dom_id}
          data-tagging-mode={membership.tagging_mode}
          class="flex items-center justify-between gap-3 px-3 py-2"
        >
          <.link
            navigate={~p"/network/vlans/#{membership.vlan.id}"}
            class="font-mono text-sm text-fg hover:underline"
          >
            {membership.vlan.vid} · {membership.vlan.name}
          </.link>
          <span class="text-xs text-fg-muted">{String.capitalize(membership.tagging_mode)}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :mode, :any, required: true
  attr :memberships, :integer, default: 0
  attr :missing_value, :string, required: true
  attr :membership_missing_value, :string, required: true
  attr :without_mode_note, :string, required: true

  defp mode_datum(assigns) do
    ~H"""
    <div id={@id} class="rounded-md bg-sunken px-3 py-2">
      <dt class="text-xs text-fg-muted">{@label}</dt>
      <dd class="mt-0.5 text-sm font-medium text-fg">
        {mode_value(@mode, @memberships, @missing_value, @membership_missing_value)}
        <p :if={is_nil(@mode) and @memberships > 0} class="mt-0.5 text-xs font-normal text-fg-muted">
          {@without_mode_note}
        </p>
      </dd>
    </div>
    """
  end

  # The current mode is a reconciled projection. When it is absent we call the value
  # unavailable rather than claiming the collector reported nothing, because reported mode
  # evidence is also suppressed when it conflicts with the observed membership.
  defp mode_value(%{mode: mode}, _memberships, _missing, _membership_missing),
    do: mode |> to_string() |> String.capitalize()

  defp mode_value(nil, 0, missing, _membership_missing), do: missing
  defp mode_value(nil, _memberships, _missing, membership_missing), do: membership_missing

  # Extracted from handle_event/3 so the handler keeps only input validation;
  # this maps Topology.create_vlan/3 outcomes to flashes.
  defp create_vlan(socket, scope, params, name, vid) do
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
        socket
        |> put_flash(:info, "VLAN #{vlan.vid} created")
        |> assign(:vlan_form, vlan_form())
        |> close_overlay("vlan-panel")
        |> load_vlans(socket.assigns.group_filter)

      {:error, :forbidden} ->
        put_flash(socket, :error, "You are not allowed to manage VLANs")

      {:error, %Ecto.Changeset{} = changeset} ->
        put_flash(socket, :error, first_error(changeset))

      {:error, reason} ->
        put_flash(socket, :error, mutation_error(reason))
    end
  end

  defp load_vlans(socket, group_filter) do
    scope = socket.assigns.current_scope
    groups = Topology.list_vlan_groups(scope)
    all_vlans = Topology.list_vlans(scope)
    vlans = filter_vlans(all_vlans, group_filter)
    vids_by_group = Enum.group_by(all_vlans, & &1.vlan_group_id, & &1.vid)

    socket
    |> assign(
      groups: groups,
      group_usage:
        Enum.map(groups, &{&1, VlanUsage.strip(&1, Map.get(vids_by_group, &1.id, []))}),
      vlan_count: length(vlans),
      member_counts: Topology.vlan_member_counts(scope),
      prefixes_by_vlan: prefixes_by_vlan(scope),
      group_filter_options:
        [{"All VLANs", "all"}, {"No group (global)", "global"}] ++
          Enum.map(groups, &{&1.resource.name, &1.id}),
      vlan_group_options:
        [{"No group (global)", ""}] ++ Enum.map(groups, &{&1.resource.name, &1.id})
    )
    |> stream(:vlans, vlans, dom_id: &"vlan-#{&1.id}", reset: true)
  end

  defp filter_vlans(vlans, "all"), do: vlans
  defp filter_vlans(vlans, "global"), do: Enum.filter(vlans, &is_nil(&1.vlan_group_id))
  defp filter_vlans(vlans, group_id), do: Enum.filter(vlans, &(&1.vlan_group_id == group_id))

  # One organization-scoped relationship query keeps the prefix chips in step with
  # the VLAN stream without a per-row lookup.
  defp prefixes_by_vlan(scope) do
    scope
    |> Topology.list_prefix_vlan_relationships()
    |> Enum.group_by(& &1.vlan_id, & &1.prefix)
    |> Map.new(fn {vlan_id, prefixes} ->
      {vlan_id, Enum.sort_by(prefixes, &{&1.prefix.address, &1.prefix.netmask})}
    end)
  end

  defp load_membership(socket, nil) do
    socket
    |> assign(:resource, nil)
    |> assign(:desired_mode, nil)
    |> assign(:current_mode, nil)
    |> assign(:desired_membership_count, 0)
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
    |> assign(:desired_membership_count, length(desired))
    |> assign(:current_membership_count, length(current))
    |> stream(:desired_memberships, desired, dom_id: &"desired-membership-#{&1.id}", reset: true)
    |> stream(:current_memberships, current, dom_id: &"current-membership-#{&1.id}", reset: true)
  end

  defp member_count(counts, vlan, side), do: get_in(counts, [vlan.id, side]) || 0

  defp normalize_group_filter(value) when value in [nil, ""], do: "all"
  defp normalize_group_filter(value), do: value

  defp vlans_path(%Phoenix.LiveView.Socket{assigns: assigns}, overrides),
    do: vlans_path(assigns.group_filter, assigns.interface_id, overrides)

  defp vlans_path(group_filter, interface_id, overrides) do
    params =
      %{"group_id" => group_filter, "interface_id" => interface_id}
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {key, value} ->
        value in [nil, ""] or {key, value} == {"group_id", "all"}
      end)
      |> Map.new()

    ~p"/network/vlans?#{params}"
  end

  defp vlan_group_name(%{vlan_group: nil}), do: "No group"
  defp vlan_group_name(%{vlan_group: group}), do: group.resource.name

  defp filter_label("all", _groups), do: "All VLANs"
  defp filter_label("global", _groups), do: "VLANs outside every group"

  defp filter_label(group_id, groups) do
    case Enum.find(groups, &(&1.id == group_id)) do
      nil -> "VLANs"
      group -> "VLANs in #{group.resource.name}"
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

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp mutation_error(:vlan_out_of_range), do: "The VID is outside the selected group's ranges"
  defp mutation_error(_reason), do: "The VLAN could not be created"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "The VLAN could not be created"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end
end
