defmodule RengaWeb.VlanDetailLive do
  @moduledoc """
  One VLAN (RFD 8, "VLANs"): its interfaces with planned versus observed
  membership, and the prefixes it carries.

  Membership differences sort first, and `?show=differences` hides the
  interfaces where plan and observation agree. Owners and admins link and
  unlink prefixes here; unlinking never deletes either record.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.IPAM
  alias Renga.Topology
  alias Renga.Topology.VlanUsage
  alias RengaWeb.VlanComponents

  @reload_after_ms 400

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    vlan = Topology.get_vlan!(scope, id)
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       vlan: vlan,
       page_title: "VLAN #{vlan.vid} #{vlan.name}",
       can_manage?: Inventory.organization_manager?(scope),
       prefix_form: prefix_form(),
       reload_timer: nil
     )
     |> load_prefixes()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    show = if params["show"] == "differences", do: :differences, else: :all
    {:noreply, socket |> assign(:show, show) |> load_members()}
  end

  @impl true
  def handle_event("validate_prefix", %{"prefix_vlan" => params}, socket) do
    {:noreply, assign(socket, :prefix_form, to_form(params, as: :prefix_vlan))}
  end

  def handle_event("attach_prefix", %{"prefix_vlan" => %{"prefix_id" => prefix_id}}, socket) do
    cond do
      prefix_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Choose the IP prefix to link")}

      # Malformed IDs cannot match any prefix; treat them like missing ones
      # instead of crashing the LiveView on a query-cast error.
      not valid_uuid?(prefix_id) ->
        {:noreply, socket |> put_flash(:error, unavailable_message()) |> load_prefixes()}

      true ->
        {:noreply, attach_prefix(socket, prefix_id)}
    end
  end

  def handle_event("detach_prefix", %{"prefix-id" => prefix_id}, socket) do
    if valid_uuid?(prefix_id) do
      {:noreply, detach_prefix(socket, prefix_id)}
    else
      {:noreply, socket |> put_flash(:error, unavailable_message()) |> load_prefixes()}
    end
  end

  @impl true
  def handle_info(
        {:inventory_changed, _organization_id},
        %{assigns: %{reload_timer: nil}} = socket
      ) do
    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info({:inventory_changed, _organization_id}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_members() |> load_prefixes()}
  end

  # attach_prefix_vlan raises Ecto.NoResultsError for a stale or foreign
  # prefix inside its transaction; surface it as a recoverable message.
  defp attach_prefix(socket, prefix_id) do
    %{current_scope: scope, vlan: vlan} = socket.assigns

    case Topology.attach_prefix_vlan(scope, prefix_id, vlan.id) do
      {:ok, relationship} ->
        socket
        |> put_flash(:info, "Linked IP prefix #{VlanComponents.prefix_cidr(relationship.prefix)}")
        |> assign(:prefix_form, prefix_form())
        |> load_prefixes()

      {:error, :forbidden} ->
        put_flash(socket, :error, "You are not allowed to manage VLANs")

      {:error, %Ecto.Changeset{} = changeset} ->
        put_flash(socket, :error, first_error(changeset))

      {:error, _reason} ->
        put_flash(socket, :error, "The prefix could not be linked")
    end
  rescue
    Ecto.NoResultsError ->
      socket |> put_flash(:error, unavailable_message()) |> load_prefixes()
  end

  defp detach_prefix(socket, prefix_id) do
    %{current_scope: scope, vlan: vlan} = socket.assigns

    case Topology.detach_prefix_vlan(scope, prefix_id, vlan.id) do
      {:ok, _relationship} ->
        socket |> put_flash(:info, "Unlinked the IP prefix") |> load_prefixes()

      # A concurrent unlink already removed it; refresh the visible list.
      {:error, :not_found} ->
        load_prefixes(socket)

      {:error, :forbidden} ->
        put_flash(socket, :error, "You are not allowed to manage VLANs")
    end
  rescue
    Ecto.NoResultsError -> load_prefixes(socket)
  end

  defp load_members(socket) do
    members = Topology.list_vlan_members(socket.assigns.current_scope, socket.assigns.vlan.id)

    shown =
      if socket.assigns.show == :differences,
        do: Enum.reject(members, &(&1.state == :both)),
        else: members

    socket
    |> assign(member_counts: VlanUsage.member_counts(members), member_total: length(members))
    |> stream(:members, shown, dom_id: &"member-#{&1.interface.id}", reset: true)
  end

  defp load_prefixes(socket) do
    scope = socket.assigns.current_scope
    linked = Topology.list_vlan_prefixes(scope, socket.assigns.vlan.id)
    linked_ids = MapSet.new(linked, & &1.id)

    available =
      scope
      |> Inventory.list_prefixes()
      |> Enum.reject(&MapSet.member?(linked_ids, &1.id))

    assign(socket,
      dual_stack: IPAM.vlan_dual_stack(scope, socket.assigns.vlan.id),
      prefixes: linked,
      prefix_options:
        [{"Choose a prefix", ""}] ++
          Enum.map(
            available,
            &{"#{VlanComponents.prefix_cidr(&1)} · #{&1.resource.name}", &1.id}
          )
    )
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
      <.object_page
        id="vlan-detail"
        title={"#{@vlan.vid} · #{@vlan.name}"}
        subtitle={group_name(@vlan)}
      >
        <:breadcrumb>
          <.link navigate={~p"/network/vlans"} class="hover:text-fg">VLANs</.link>
          <span aria-hidden="true">/</span>
          <span class="text-fg">{@vlan.vid}</span>
        </:breadcrumb>
        <:icon><.icon name="hero-tag" class="size-5" /></:icon>
        <:status>
          <span class="inline-flex items-center gap-1.5 rounded-md border border-edge px-2 py-0.5 text-xs text-fg">
            <span class={["size-1.5 rounded-full", status_dot(@vlan.status)]} />
            {String.capitalize(@vlan.status)}
          </span>
        </:status>

        <div class="space-y-8">
          <section id="vlan-members-section" class="space-y-3">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 class="text-sm font-semibold text-fg">Interfaces</h2>
                <p id="vlan-member-summary" class="text-xs text-fg-muted">
                  {@member_counts.both} agree · {@member_counts.planned_only} planned, not observed · {@member_counts.observed_only} observed, not planned · {@member_counts.tagging_differs} tagged differently
                </p>
              </div>
              <.segmented id="vlan-member-filter" label="Show interfaces">
                <:option
                  id="vlan-members-all"
                  patch={~p"/network/vlans/#{@vlan.id}"}
                  active={@show == :all}
                >
                  All {@member_total}
                </:option>
                <:option
                  id="vlan-members-differences"
                  patch={~p"/network/vlans/#{@vlan.id}?show=differences"}
                  active={@show == :differences}
                >
                  Differences {@member_total - @member_counts.both}
                </:option>
              </.segmented>
            </div>

            <.table
              id="vlan-members"
              rows={@streams.members}
              class="rounded-lg border border-edge bg-surface"
            >
              <:col :let={{_id, member}} label="Interface">
                <span class="flex min-w-0 items-baseline gap-1.5 pt-1.5 sm:pb-1.5">
                  <span class="font-mono text-sm text-fg">{member.interface.name}</span>
                  <.link
                    navigate={~p"/inventory/#{member.interface.resource_id}"}
                    class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
                  >
                    {member.interface.resource.name}
                  </.link>
                </span>
                <%!-- On a phone the state rides under the interface instead of
                      in a column that would scroll out of view. --%>
                <span class={["block pb-1.5 text-xs sm:hidden", state_class(member.state)]}>
                  {state_label(member.state)}
                </span>
              </:col>
              <:col :let={{_id, member}} label="Planned">
                <.tagging value={member.planned} />
              </:col>
              <:col :let={{_id, member}} label="Observed">
                <.tagging value={member.observed} />
              </:col>
              <:col :let={{_id, member}} label="State" class="hidden sm:table-cell">
                <span
                  data-member-state={member.state}
                  class={["whitespace-nowrap text-xs", state_class(member.state)]}
                >
                  {state_label(member.state)}
                </span>
              </:col>
              <:empty>
                {if @show == :differences,
                  do: "Planned and observed membership agree on every interface.",
                  else: "No interface plans or reports this VLAN."}
              </:empty>
            </.table>
          </section>

          <section :if={@dual_stack} id="vlan-dual-stack" class="space-y-3">
            <div>
              <h2 class="text-sm font-semibold text-fg">Dual stack</h2>
              <p id="vlan-dual-stack-summary" class="text-xs text-fg-muted">
                <span class="font-mono text-fg">
                  {length(@dual_stack.both)} of {@dual_stack.total}
                </span>
                devices within this VLAN's Global-table prefixes have both IPv4 and IPv6.
              </p>
              <p class="text-xs text-fg-muted">
                VRF prefixes are not part of this coverage.
              </p>
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <.coverage_list
                id="vlan-missing-ipv6"
                title="Missing IPv6 in Global prefixes"
                devices={@dual_stack.missing_ipv6}
              />
              <.coverage_list
                id="vlan-missing-ipv4"
                title="Missing IPv4 in Global prefixes"
                devices={@dual_stack.missing_ipv4}
              />
            </div>
          </section>

          <section id="vlan-prefixes" class="space-y-3">
            <div>
              <h2 class="text-sm font-semibold text-fg">IP prefixes</h2>
              <p class="text-xs text-fg-muted">
                A prefix may serve several VLANs and a VLAN may carry several prefixes.
              </p>
            </div>
            <ul class="divide-y divide-edge rounded-lg border border-edge bg-surface">
              <li
                :if={@prefixes == []}
                id="vlan-prefixes-empty"
                class="px-3 py-4 text-sm text-fg-muted"
              >
                No prefixes are linked to this VLAN.
              </li>
              <li
                :for={prefix <- @prefixes}
                id={"vlan-prefix-#{prefix.id}"}
                data-prefix-cidr={VlanComponents.prefix_cidr(prefix)}
                class="flex min-h-tap items-center gap-3 px-3"
              >
                <span class="font-mono text-sm text-fg">{VlanComponents.prefix_cidr(prefix)}</span>
                <.link
                  navigate={~p"/inventory/#{prefix.resource_id}"}
                  class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
                >
                  {prefix.resource.name}
                </.link>
                <.button
                  :if={@can_manage?}
                  id={"vlan-prefix-#{prefix.id}-detach"}
                  variant="ghost"
                  size="sm"
                  class="ml-auto"
                  phx-click="detach_prefix"
                  phx-value-prefix-id={prefix.id}
                  aria-label={"Unlink IP prefix #{VlanComponents.prefix_cidr(prefix)}"}
                >
                  Unlink
                </.button>
              </li>
            </ul>

            <.form
              :if={@can_manage?}
              for={@prefix_form}
              id="prefix-vlan-form"
              phx-change="validate_prefix"
              phx-submit="attach_prefix"
              class="flex flex-wrap items-end gap-3"
            >
              <div class="w-72 max-w-full">
                <.input
                  field={@prefix_form[:prefix_id]}
                  type="select"
                  label="Link a prefix"
                  options={@prefix_options}
                />
              </div>
              <.button
                id="prefix-vlan-form-submit"
                type="submit"
                disabled={length(@prefix_options) <= 1}
                class="mb-2"
              >
                Link prefix
              </.button>
              <p
                :if={length(@prefix_options) <= 1}
                id="prefix-vlan-form-empty"
                class="mb-3 w-full text-xs text-fg-muted"
              >
                No other IP prefixes are recorded.
              </p>
            </.form>
          </section>
        </div>

        <:aside>
          <.properties id="vlan-properties" title="VLAN">
            <:item label="VID"><span class="font-mono">{@vlan.vid}</span></:item>
            <:item label="Group">
              {group_name(@vlan)}
              <span :if={@vlan.vlan_group} class="block font-mono text-[11px] text-fg-muted">
                {VlanComponents.ranges_label(@vlan.vlan_group)}
              </span>
            </:item>
            <:item label="Role" blank={is_nil(@vlan.role)} placeholder="No role">{@vlan.role}</:item>
            <:item label="Description" blank={is_nil(@vlan.description)} placeholder="None">
              {@vlan.description}
            </:item>
          </.properties>
        </:aside>
      </.object_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :devices, :list, required: true

  defp coverage_list(assigns) do
    ~H"""
    <div id={@id} class="space-y-1.5 rounded-md border border-edge bg-surface p-3">
      <h3 class="text-xs font-medium text-fg-muted">
        {@title} <span class="font-mono tabular-nums">{length(@devices)}</span>
      </h3>
      <p :if={@devices == []} class="text-xs text-fg-subtle">None.</p>
      <ul :if={@devices != []} class="flex flex-wrap gap-1.5">
        <li :for={device <- @devices}>
          <.link
            navigate={~p"/inventory/#{device.id}"}
            class="rounded border border-warn-line bg-warn-fill px-1.5 text-xs text-warn-text hover:underline"
          >
            {device.name}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :value, :string, default: nil

  defp tagging(assigns) do
    ~H"""
    <span :if={@value} class="text-sm text-fg">{String.capitalize(@value)}</span>
    <span :if={!@value} class="text-fg-subtle">—</span>
    """
  end

  defp state_label(:both), do: "Agrees"
  defp state_label(:tagging_differs), do: "Tagged differently"
  defp state_label(:planned_only), do: "Planned, not observed"
  defp state_label(:observed_only), do: "Observed, not planned"

  defp state_class(:both), do: "text-fg-muted"
  defp state_class(_difference), do: "font-medium text-warn-text"

  defp status_dot("active"), do: "bg-ok"
  defp status_dot(_status), do: "bg-fg-subtle"

  defp group_name(%{vlan_group: nil}), do: "No group"
  defp group_name(%{vlan_group: group}), do: group.resource.name

  defp prefix_form, do: to_form(%{"prefix_id" => ""}, as: :prefix_vlan)

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp unavailable_message, do: "The chosen IP prefix is no longer available"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "The prefix could not be linked"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end
end
