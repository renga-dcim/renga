defmodule RengaWeb.ResourcePortsLive do
  @moduledoc """
  A switch's Ports tab (RFD 8, "Switch ports"): a front panel colored by
  port state, then a port table with link speed, LLDP neighbor, cable, VLAN
  mode, and untagged and tagged VLANs.

  Selecting a port (`?port=`), from the panel or the table, expands its row
  in place. A port with VLAN drift shows its desired and observed
  membership there, with the VLANs reconciliation flags as missing or
  unexpected marked. Neighbor and cable link to the topology panel, where
  cable changes are made.

  A switch has a bounded number of ports and the front panel needs all of
  them at once, so ports are a plain assign rather than a stream.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents
  import RengaWeb.TopologyComponents, only: [line_sample: 1, state_label: 1]

  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Topology
  alias Renga.Topology.Ports

  @reload_after_ms 400

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_operational_resource!(scope, id)

    if resource.kind != "switch" do
      {:ok, push_navigate(socket, to: ~p"/inventory/#{resource}/network")}
    else
      if connected?(socket), do: Changes.subscribe(scope)

      {:ok,
       socket
       |> assign(
         resource: resource,
         page_title: "#{resource.name} ports",
         hardware?: Catalog.hardware_assignable_resource?(resource),
         reload_timer: nil
       )
       |> load_ports()}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected, params["port"])}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info(:reload, socket) do
    resource =
      Inventory.get_operational_resource!(
        socket.assigns.current_scope,
        socket.assigns.resource.id
      )

    {:noreply, socket |> assign(resource: resource, reload_timer: nil) |> load_ports()}
  end

  defp load_ports(socket) do
    ports = Topology.list_resource_ports(socket.assigns.current_scope, socket.assigns.resource.id)

    assign(socket,
      ports: ports,
      up_count: Enum.count(ports, &(&1.interface.status == "up")),
      drift_count: Enum.count(ports, &Ports.drift?/1)
    )
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
      <.resource_frame resource={@resource} tab={:ports} hardware?={@hardware?}>
        <div id="resource-ports" class="space-y-6">
          <p id="ports-summary" class="text-sm text-fg-muted">
            <span class="font-mono tabular-nums text-fg">{length(@ports)}</span>
            ports, <span class="font-mono tabular-nums text-fg">{@up_count}</span>
            up<span :if={@drift_count > 0}>,
              <span class="font-mono tabular-nums text-warn-text">{@drift_count}</span>
              with VLAN drift</span>.
            <.link
              navigate={~p"/network/topology?#{[resource: @resource.id]}"}
              class="text-link hover:underline"
            >
              See it on the topology map
            </.link>
          </p>

          <p
            :if={@ports == []}
            id="ports-empty"
            class="rounded-lg border border-dashed border-edge px-4 py-10 text-center text-sm text-fg-muted"
          >
            No physical ports are reported for this switch yet.
          </p>

          <.front_panel :if={@ports != []} ports={@ports} selected={@selected} resource={@resource} />

          <%!-- relative keeps the sr-only header inside the scroll box, so a wide
               expanded row scrolls the table rather than the page. --%>
          <div
            :if={@ports != []}
            class="relative overflow-x-auto rounded-lg border border-edge bg-surface"
          >
            <table id="ports" class="w-full text-left text-table text-fg">
              <thead class="text-xs text-fg-muted">
                <tr class="h-row border-b border-edge">
                  <th scope="col" class="px-cell font-medium">Port</th>
                  <th scope="col" class="hidden px-cell font-medium sm:table-cell">Speed</th>
                  <th scope="col" class="px-cell font-medium">Neighbor</th>
                  <th scope="col" class="hidden px-cell font-medium md:table-cell">Cable</th>
                  <th scope="col" class="hidden px-cell font-medium sm:table-cell">Mode</th>
                  <th scope="col" class="px-cell font-medium">Untagged</th>
                  <th scope="col" class="hidden px-cell font-medium md:table-cell">Tagged</th>
                  <th scope="col" class="px-cell"><span class="sr-only">Details</span></th>
                </tr>
              </thead>
              <tbody>
                <%= for port <- @ports do %>
                  <.port_row port={port} selected={@selected} resource={@resource} />
                  <tr
                    :if={@selected == port.interface.id}
                    id={"port-#{port.interface.id}-details"}
                    class="border-b border-line bg-canvas"
                  >
                    <td colspan="8" class="px-cell py-4">
                      <.port_details port={port} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </.resource_frame>
    </Layouts.app>
    """
  end

  attr :ports, :list, required: true
  attr :selected, :string, default: nil
  attr :resource, :any, required: true

  # Switches number ports in columns, odd on top and even below, so the panel
  # does too: reading it matches looking at the device.
  defp front_panel(assigns) do
    {top, bottom} =
      assigns.ports
      |> Enum.with_index()
      |> Enum.split_with(fn {_port, index} -> rem(index, 2) == 0 end)

    assigns = assign(assigns, rows: [Enum.map(top, &elem(&1, 0)), Enum.map(bottom, &elem(&1, 0))])

    ~H"""
    <section id="front-panel" aria-label="Front panel" class="space-y-3">
      <div class="overflow-x-auto">
        <div class="inline-flex flex-col gap-1.5 rounded-lg border border-edge bg-sunken p-2.5">
          <div :for={row <- @rows} class="flex gap-1.5">
            <button
              :for={port <- row}
              type="button"
              id={"panel-port-#{port.interface.id}"}
              phx-click={
                JS.patch(port_path(@resource, port, @selected))
                |> JS.focus(to: "#port-#{port.interface.id}-open")
              }
              data-status={port_status(port)}
              data-drift={to_string(Ports.drift?(port))}
              aria-label={"#{port.interface.name}, #{status_label(port)}#{if Ports.drift?(port), do: ", VLAN drift"}"}
              aria-pressed={to_string(@selected == port.interface.id)}
              title={"#{port.interface.name} · #{status_label(port)}"}
              class={[
                "relative grid h-7 w-8 cursor-pointer place-items-center rounded-sm border font-mono text-[10px] transition-colors",
                "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent",
                port_class(port_status(port)),
                @selected == port.interface.id &&
                  "ring-2 ring-accent ring-offset-1 ring-offset-sunken"
              ]}
            >
              {port_number(port)}
              <span
                :if={Ports.drift?(port)}
                class="absolute -right-1 -top-1 size-2 rotate-45 border border-surface bg-warn"
                aria-hidden="true"
              />
            </button>
          </div>
        </div>
      </div>
      <ul id="front-panel-legend" class="flex flex-wrap gap-x-4 gap-y-1.5 text-xs text-fg-muted">
        <li :for={status <- ~w(up down unknown)} class="flex items-center gap-1.5">
          <span class={["size-3 rounded-sm border", port_class(status)]} aria-hidden="true" />
          {String.capitalize(status)}
        </li>
        <li class="flex items-center gap-1.5">
          <span class="size-2 rotate-45 bg-warn" aria-hidden="true" /> VLAN drift
        </li>
      </ul>
    </section>
    """
  end

  attr :port, Ports, required: true
  attr :selected, :string, default: nil
  attr :resource, :any, required: true

  defp port_row(assigns) do
    assigns = assign(assigns, :id, assigns.port.interface.id)

    ~H"""
    <tr
      id={"port-#{@id}"}
      data-drift={to_string(Ports.drift?(@port))}
      aria-current={@selected == @id && "true"}
      class={[
        "h-row border-b border-line transition-colors",
        if(@selected == @id, do: "bg-accent-tint", else: "hover:bg-sunken/60")
      ]}
    >
      <td class="px-cell">
        <.link
          id={"port-#{@id}-open"}
          patch={port_path(@resource, @port, @selected)}
          aria-expanded={to_string(@selected == @id)}
          aria-controls={"port-#{@id}-details"}
          class="flex min-h-[max(var(--rg-row-h)-1px,var(--rg-tap-min))] items-center gap-2 rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
        >
          <span class={["size-2 shrink-0 rounded-full", dot_class(port_status(@port))]} />
          <span class="font-mono text-sm">{@port.interface.name}</span>
        </.link>
      </td>
      <td class="hidden px-cell font-mono text-xs text-fg-muted sm:table-cell">
        {speed(@port.interface.speed_mbps)}
      </td>
      <td class="px-cell"><.neighbor port={@port} /></td>
      <td class="hidden px-cell md:table-cell"><.cable port={@port} /></td>
      <td class="hidden px-cell text-xs sm:table-cell"><.mode port={@port} /></td>
      <td class="px-cell font-mono text-xs">
        <.vlan_side port={@port} pick={:untagged} />
      </td>
      <td class="hidden px-cell font-mono text-xs md:table-cell">
        <.vlan_side port={@port} pick={:tagged} />
      </td>
      <td class="w-0 px-cell">
        <.link
          :if={Ports.drift?(@port)}
          id={"port-#{@id}-drift"}
          patch={port_path(@resource, @port, @selected)}
          class="inline-flex items-center gap-1 whitespace-nowrap rounded border border-warn-line bg-warn-fill px-1.5 py-0.5 text-[11px] font-medium text-warn-text"
        >
          VLAN drift
          <.icon
            name={if(@selected == @id, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini")}
            class="size-3.5"
          />
        </.link>
      </td>
    </tr>
    """
  end

  attr :port, Ports, required: true

  defp neighbor(assigns) do
    ~H"""
    <%= cond do %>
      <% @port.neighbor -> %>
        <.far_link port={@port} link={@port.neighbor} />
      <% @port.unresolved != [] -> %>
        <span
          class="inline-flex items-center gap-1.5 text-xs text-fg-muted"
          title="Not matched to inventory"
        >
          <.icon name="hero-question-mark-circle-mini" class="size-3.5 shrink-0" />
          <span class="font-mono">
            {hd(@port.unresolved).remote_chassis_id}:{hd(@port.unresolved).remote_port_id}
          </span>
        </span>
      <% true -> %>
        <span class="text-fg-subtle">—</span>
    <% end %>
    """
  end

  attr :port, Ports, required: true

  defp cable(assigns) do
    ~H"""
    <%= cond do %>
      <% @port.cable -> %>
        <.far_link port={@port} link={@port.cable} label={@port.cable.cable.label} />
      <% @port.plan -> %>
        <.far_link port={@port} link={@port.plan} label="planned" />
      <% true -> %>
        <span class="text-fg-subtle">—</span>
    <% end %>
    """
  end

  attr :port, Ports, required: true
  attr :link, :any, required: true
  attr :label, :string, default: nil

  defp far_link(assigns) do
    assigns = assign(assigns, :far, Ports.far_end(assigns.port, assigns.link))

    ~H"""
    <.link
      navigate={~p"/network/topology?#{[link: @link.key]}"}
      title={state_label(@link.state)}
      class="group inline-flex min-w-0 items-center gap-1.5 text-xs"
    >
      <.line_sample state={@link.state} class="w-5" />
      <span class="font-mono text-fg group-hover:underline">{@far.name}</span>
      <span class="truncate text-fg-muted">{@far.resource.name}</span>
      <span :if={@label} class="truncate text-fg-subtle">{@label}</span>
    </.link>
    """
  end

  attr :port, Ports, required: true

  defp mode(assigns) do
    ~H"""
    <%= cond do %>
      <% @port.observed && @port.observed.mode -> %>
        {mode_label(@port.observed.mode)}
      <% @port.desired && @port.desired.mode -> %>
        <span class="text-fg-muted" title="Desired; not observed">
          {mode_label(@port.desired.mode)}
        </span>
      <% true -> %>
        <span class="text-fg-subtle">—</span>
    <% end %>
    """
  end

  attr :port, Ports, required: true
  attr :pick, :atom, required: true

  # The table shows what collectors observe; where nothing is observed yet it
  # shows the desired membership, muted, so intent is not mistaken for fact.
  defp vlan_side(assigns) do
    side = assigns.port.observed || assigns.port.desired

    assigns =
      assign(assigns,
        text: side && vlan_text(side, assigns.pick),
        desired_only?: is_nil(assigns.port.observed) and not is_nil(side)
      )

    ~H"""
    <span
      :if={@text}
      class={[@desired_only? && "text-fg-muted"]}
      title={@desired_only? && "Desired; not observed"}
    >
      {@text}
    </span>
    <span :if={!@text} class="text-fg-subtle">—</span>
    """
  end

  attr :port, Ports, required: true

  defp port_details(assigns) do
    ~H"""
    <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
      <div class="space-y-3">
        <div id={"port-#{@port.interface.id}-membership"} class="grid gap-3 sm:grid-cols-2">
          <.membership
            title="Desired"
            side={@port.desired}
            flagged={@port.missing}
            flag="Missing"
            empty="No VLAN intent for this port."
          />
          <.membership
            title="Observed"
            side={@port.observed}
            flagged={@port.unexpected}
            flag="Unexpected"
            empty="No collector reports this port's VLANs."
          />
        </div>
        <ul :if={@port.findings != []} class="space-y-1">
          <li
            :for={finding <- @port.findings}
            class="flex items-center gap-1.5 text-xs text-warn-text"
          >
            <.icon name="hero-exclamation-triangle-mini" class="size-3.5 shrink-0" />
            <span :if={finding_vid(@port, finding)} class="font-mono">
              VLAN {finding_vid(@port, finding)}:
            </span>
            {finding.message}
          </li>
        </ul>
        <.link
          :if={@port.findings != []}
          navigate={~p"/inbox?#{[domain: "topology", interface_id: @port.interface.id]}"}
          class="inline-flex items-center gap-1 text-xs text-link hover:underline"
        >
          <.icon name="hero-inbox-mini" class="size-3.5" /> Open in Inbox
        </.link>
      </div>

      <dl class="space-y-2 text-xs">
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Status</dt>
          <dd>{status_label(@port)}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Speed</dt>
          <dd class="font-mono">{speed(@port.interface.speed_mbps)}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Neighbor</dt>
          <dd class="min-w-0"><.neighbor port={@port} /></dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Cable</dt>
          <dd class="min-w-0"><.cable port={@port} /></dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :side, :any, required: true
  attr :flagged, :list, required: true
  attr :flag, :string, required: true
  attr :empty, :string, required: true

  defp membership(assigns) do
    assigns =
      assign(assigns, :flagged_ids, MapSet.new(assigns.flagged, &{&1.tagging, &1.vlan.id}))

    ~H"""
    <section class="space-y-2 rounded-md border border-edge bg-surface p-3">
      <h3 class="text-xs font-medium text-fg-muted">{@title}</h3>
      <p :if={!@side} class="text-xs text-fg-subtle">{@empty}</p>
      <dl :if={@side} class="space-y-1.5 text-xs">
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Mode</dt>
          <dd>{(@side.mode && mode_label(@side.mode)) || "—"}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Untagged</dt>
          <dd class="flex flex-wrap gap-1">
            <.vlan_chip
              :if={@side.untagged}
              vlan={@side.untagged}
              flag={MapSet.member?(@flagged_ids, {:untagged, @side.untagged.id}) && @flag}
            />
            <span :if={!@side.untagged} class="text-fg-subtle">—</span>
          </dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-16 shrink-0 text-fg-muted">Tagged</dt>
          <dd class="flex flex-wrap gap-1">
            <span :if={@side.mode == "tagged_all"} class="text-fg">All VLANs</span>
            <.vlan_chip
              :for={vlan <- @side.tagged}
              vlan={vlan}
              flag={MapSet.member?(@flagged_ids, {:tagged, vlan.id}) && @flag}
            />
            <span :if={@side.tagged == [] and @side.mode != "tagged_all"} class="text-fg-subtle">
              —
            </span>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :vlan, :any, required: true
  attr :flag, :any, default: false

  defp vlan_chip(assigns) do
    ~H"""
    <span
      data-vlan={@vlan.vid}
      data-flag={@flag && String.downcase(@flag)}
      title={if(@flag, do: "#{@flag}: #{@vlan.name}", else: @vlan.name)}
      class={[
        "inline-flex items-center gap-1 rounded border px-1.5 font-mono text-[11px]",
        if(@flag,
          do: "border-warn-line bg-warn-fill text-warn-text",
          else: "border-edge bg-sunken text-fg"
        )
      ]}
    >
      {@vlan.vid}<span :if={@flag} class="font-sans">{String.downcase(@flag)}</span>
    </span>
    """
  end

  # Names the VLAN a finding is about when it is one of the port's VLANs.
  defp finding_vid(port, finding) do
    vlan_id = get_in(finding.details, ["vlan_id"])

    [port.desired, port.observed]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&(List.wrap(&1.untagged) ++ &1.tagged))
    |> Enum.find_value(&(&1.id == vlan_id && &1.vid))
  end

  # Selecting the open port closes it again.
  defp port_path(resource, port, selected) do
    if selected == port.interface.id,
      do: ~p"/inventory/#{resource}/ports",
      else: ~p"/inventory/#{resource}/ports?#{[port: port.interface.id]}"
  end

  defp port_status(%{interface: %{status: "up"}}), do: "up"
  defp port_status(%{interface: %{status: status}}) when status in ~w(down dormant), do: "down"
  defp port_status(_port), do: "unknown"

  defp status_label(%{interface: %{status: status}}), do: String.replace(status, "_", " ")

  defp port_class("up"), do: "border-ok bg-ok/20 text-fg hover:bg-ok/35"
  defp port_class("down"), do: "border-edge bg-surface text-fg-muted hover:bg-canvas"
  defp port_class(_unknown), do: "border-dashed border-fg-subtle bg-surface text-fg-subtle"

  defp dot_class("up"), do: "bg-ok"
  defp dot_class("down"), do: "bg-fg-subtle"
  defp dot_class(_unknown), do: "border border-dashed border-fg-subtle"

  # The panel labels a port by its last number (swp12 -> 12, Ethernet1/12 -> 12).
  defp port_number(port) do
    case Regex.scan(~r/\d+/, port.interface.name) do
      [] -> String.slice(port.interface.name, 0, 3)
      numbers -> numbers |> List.last() |> hd()
    end
  end

  defp speed(nil), do: "—"
  defp speed(mbps) when mbps >= 1000 and rem(mbps, 1000) == 0, do: "#{div(mbps, 1000)}G"
  defp speed(mbps) when mbps >= 1000, do: "#{Float.round(mbps / 1000, 1)}G"
  defp speed(mbps), do: "#{mbps}M"

  defp mode_label("access"), do: "Access"
  defp mode_label("trunk"), do: "Trunk"
  defp mode_label("tagged_all"), do: "Trunk, all VLANs"
  defp mode_label(mode), do: mode

  defp vlan_text(%{untagged: nil}, :untagged), do: nil
  defp vlan_text(%{untagged: vlan}, :untagged), do: to_string(vlan.vid)
  defp vlan_text(%{mode: "tagged_all"}, :tagged), do: "all"
  defp vlan_text(%{tagged: []}, :tagged), do: nil
  defp vlan_text(%{tagged: tagged}, :tagged), do: tagged |> Enum.map(& &1.vid) |> ranges()

  # Compresses VIDs into ranges: [10, 11, 12, 20] -> "10–12, 20".
  defp ranges(vids) do
    vids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn
        vid, [last | _rest] = run when vid == last + 1 -> {:cont, [vid | run]}
        vid, [] -> {:cont, [vid]}
        vid, run -> {:cont, Enum.reverse(run), [vid]}
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.map_join(", ", fn
      [vid] -> to_string(vid)
      run -> "#{hd(run)}–#{List.last(run)}"
    end)
  end
end
