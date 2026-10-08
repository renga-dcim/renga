defmodule RengaWeb.TopologyLive do
  @moduledoc """
  Network topology (RFD 8): every link with its cable plan, LLDP/CDP
  evidence, and confirmed cable record kept side by side.

  The map draws devices in tiers and encodes each link's agreement in its
  line style; the table below lists every link the map summarises.
  Selecting a link (`?link=`) opens the three layers in a panel. The only
  actions there are explicit operator assertions - recording or retracting
  a cable - so evidence never changes the cable record on its own.

  `?resource=` focuses the page on one device and `?interface_id=` on one
  port, which is where resource pages link to.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.TopologyComponents

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Topology
  alias Renga.Topology.CableReconciler
  alias Renga.Topology.LinkMap
  alias Renga.Topology.Links
  alias RengaWeb.Format

  @reload_after_ms 400
  @table_limit 200

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Topology",
       can_manage?: Inventory.organization_manager?(scope),
       filters: nil,
       link_key: nil,
       selected: nil,
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      interface_id: uuid(params["interface_id"]),
      resource_id: uuid(params["resource"])
    }

    socket =
      if filters == socket.assigns.filters,
        do: socket,
        else: socket |> assign(:filters, filters) |> load_filters() |> load_topology()

    {:noreply, socket |> assign(:link_key, params["link"]) |> load_selected()}
  end

  @impl true
  def handle_event("select_link", %{"link" => key}, socket) do
    %{filters: filters, link_key: link_key} = socket.assigns
    {:noreply, push_patch(socket, to: topology_path(filters, link_key, link: key))}
  end

  def handle_event("record_cable", _params, socket) do
    case socket.assigns.selected do
      %Links{cable: nil} = link ->
        socket.assigns.current_scope
        |> Topology.assert_cable(%{
          interface_a_id: link.interface_a.id,
          interface_b_id: link.interface_b.id
        })
        |> cable_result(socket, "Cable recorded")

      _link ->
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("retract_cable", _params, socket) do
    case socket.assigns.selected do
      %Links{cable: %{} = cable} ->
        socket.assigns.current_scope
        |> Topology.retract_cable(%{
          interface_a_id: cable.interface_a_id,
          interface_b_id: cable.interface_b_id
        })
        |> cable_result(socket, "Cable retracted")

      _link ->
        {:noreply, refresh(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> refresh()}
  end

  defp cable_result({:ok, _assertion}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> refresh()}

  defp cable_result({:error, reason}, socket, _message) do
    {:noreply,
     put_flash(socket, :error, "The cable record did not change: #{error_text(reason)}")}
  end

  defp error_text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error_text(:unauthorized), do: "only owners and admins change cabling"
  defp error_text(reason) when is_atom(reason), do: Format.humanize(reason)
  defp error_text(_reason), do: "it could not be saved"

  defp refresh(socket), do: socket |> load_topology() |> load_selected()

  defp load_filters(socket) do
    scope = socket.assigns.current_scope
    %{interface_id: interface_id, resource_id: resource_id} = socket.assigns.filters
    interface = interface_id && Inventory.get_interface!(scope, interface_id)

    assign(socket,
      interface: interface,
      interface_resource: interface && Inventory.get_resource!(scope, interface.resource_id),
      focus: resource_id && Inventory.get_resource!(scope, resource_id)
    )
  end

  defp load_topology(socket) do
    scope = socket.assigns.current_scope
    filters = socket.assigns.filters
    opts = if filters.interface_id, do: [interface_id: filters.interface_id], else: []

    links = scope |> Topology.list_links() |> Links.filter(Map.to_list(filters))
    shown = Enum.take(links, @table_limit)
    relationships = relationships(scope, opts, filters.resource_id)
    unresolved = unresolved(scope, opts, filters.resource_id)

    socket
    |> assign(
      link_count: length(links),
      counts: Links.counts(links),
      map: LinkMap.build(links, focus: filters.resource_id),
      table_hidden: length(links) - length(shown),
      relationship_count: length(relationships),
      unresolved_count: length(unresolved)
    )
    |> stream(:links, shown, dom_id: &link_dom_id/1, reset: true)
    |> stream(:relationships, relationships, dom_id: &"relationship-#{&1.id}", reset: true)
    |> stream(:unresolved_evidence, unresolved,
      dom_id: &"neighbor-evidence-#{&1.id}",
      reset: true
    )
  end

  defp relationships(scope, opts, resource_id) do
    scope
    |> Inventory.list_organization_interface_relationships(opts)
    |> Enum.filter(
      &(is_nil(resource_id) or
          resource_id in [&1.source_interface.resource_id, &1.target_interface.resource_id])
    )
  end

  defp unresolved(scope, opts, resource_id) do
    scope
    |> Topology.list_unresolved_interface_neighbor_evidence(opts)
    |> Enum.filter(&(is_nil(resource_id) or &1.local_interface.resource_id == resource_id))
  end

  defp load_selected(%{assigns: %{link_key: nil}} = socket), do: assign(socket, :selected, nil)

  defp load_selected(socket) do
    assign(
      socket,
      :selected,
      Topology.get_link(socket.assigns.current_scope, socket.assigns.link_key)
    )
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:topology}
    >
      <section id="network-topology" class="mx-auto max-w-6xl space-y-6 px-6 py-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">Topology</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Each link shows whether the cable plan, neighbor evidence, and the cable record agree.
              Evidence never records a cable on its own.
            </p>
          </div>
          <div
            :if={@interface || @focus}
            id="topology-filters"
            class="flex flex-wrap items-center gap-2"
          >
            <span
              :if={@focus}
              id="topology-focus"
              class="inline-flex items-center gap-1.5 rounded-md border border-edge bg-surface px-2 py-1 text-xs"
            >
              <.icon name="hero-viewfinder-circle" class="size-3.5 text-fg-subtle" />
              <.link
                navigate={~p"/inventory/#{@focus.id}"}
                class="font-medium text-fg hover:underline"
              >
                {@focus.name}
              </.link>
              <.link
                id="topology-clear-focus"
                patch={topology_path(@filters, @link_key, resource: nil, link: nil)}
                class="grid size-5 place-items-center rounded text-fg-muted hover:bg-sunken hover:text-fg"
                aria-label="Show every device"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </.link>
            </span>
            <span
              :if={@interface}
              class="inline-flex items-center gap-1.5 rounded-md border border-edge bg-surface px-2 py-1 text-xs"
            >
              <.icon name="hero-funnel" class="size-3.5 text-fg-subtle" />
              <span class="font-mono text-fg">{@interface.name}</span>
              <span class="text-fg-muted">{@interface_resource.name}</span>
              <.link
                id="topology-clear-interface"
                patch={topology_path(@filters, @link_key, interface_id: nil, link: nil)}
                class="grid size-5 place-items-center rounded text-fg-muted hover:bg-sunken hover:text-fg"
                aria-label="Clear interface filter"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </.link>
            </span>
          </div>
        </header>

        <section
          id="topology-map-section"
          class="space-y-4 rounded-lg border border-edge bg-surface p-4"
        >
          <.legend id="topology-legend" counts={@counts} />

          <div
            :if={@link_count == 0}
            id="topology-map-empty"
            class="rounded-md border border-dashed border-edge px-4 py-10 text-center text-sm text-fg-muted"
          >
            No planned, seen, or recorded links{if @interface || @focus, do: " here", else: " yet"}.
          </div>
          <.link_map
            :if={@link_count > 0}
            id="topology-map"
            map={@map}
            selected={@selected && @selected.key}
            focus={@focus && @focus.id}
            node_path={&topology_path(@filters, @link_key, resource: &1.id, link: nil)}
          />
          <p :if={@map.hidden > 0} id="topology-map-hidden" class="text-xs text-fg-muted">
            {@map.hidden} more devices are in the table below. Select a device to focus the map on it.
          </p>
        </section>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
          <section id="topology-links" class="min-w-0 space-y-2">
            <h2 class="text-xs font-medium text-fg-muted">
              Links <span class="font-mono tabular-nums">{@link_count}</span>
            </h2>
            <.table
              id="links"
              rows={@streams.links}
              class="rounded-lg border border-edge bg-surface"
            >
              <:col :let={{_id, link}} label="State" class="w-0">
                <.link
                  id={"link-#{link.key}-open"}
                  patch={topology_path(@filters, @link_key, link: link.key)}
                  aria-label={"Show the plan, evidence, and cable record for #{link.interface_a.name} and #{link.interface_b.name}"}
                  class="flex min-h-[max(var(--rg-row-h)-1px,var(--rg-tap-min))] items-center rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
                >
                  <.link_state state={link.state} />
                </.link>
              </:col>
              <:col :let={{_id, link}} label="Endpoints">
                <span class="flex flex-wrap items-baseline gap-x-2 py-1.5">
                  <.endpoint interface={link.interface_a} />
                  <span class="hidden text-fg-subtle sm:inline" aria-hidden="true">↔</span>
                  <.endpoint interface={link.interface_b} />
                </span>
              </:col>
              <:col :let={{_id, link}} label="Layers" class="hidden sm:table-cell">
                <.layer_marks link={link} />
              </:col>
              <:empty>No links match.</:empty>
            </.table>
            <p :if={@table_hidden > 0} id="links-hidden" class="text-xs text-fg-muted">
              Showing the {@link_count - @table_hidden} links that most need attention. Focus a device to see the rest.
            </p>
          </section>

          <aside class="space-y-6">
            <section id="neighbor-evidence" class="space-y-2">
              <h2 class="text-xs font-medium text-fg-muted">
                Unresolved neighbors <span class="font-mono tabular-nums">{@unresolved_count}</span>
              </h2>
              <p class="text-xs text-fg-muted">
                Collectors report these neighbors, but no inventory interface matches them yet.
              </p>
              <ul
                id="unresolved-evidence-list"
                phx-update="stream"
                class="divide-y divide-edge rounded-lg border border-edge bg-surface"
              >
                <li
                  id="unresolved-evidence-empty"
                  class="hidden px-3 py-4 text-center text-xs text-fg-muted only:block"
                >
                  Every neighbor report matches inventory.
                </li>
                <li
                  :for={{dom_id, evidence} <- @streams.unresolved_evidence}
                  id={dom_id}
                  data-evidence-protocol={evidence.protocol}
                  class="space-y-0.5 px-3 py-2"
                >
                  <.endpoint interface={evidence.local_interface} />
                  <p class="flex items-center gap-1.5 font-mono text-xs text-fg-muted">
                    <.icon name="hero-arrow-long-right-mini" class="size-3.5 shrink-0" />
                    <span class="truncate">
                      {evidence.remote_chassis_id}:{evidence.remote_port_id}
                    </span>
                  </p>
                  <p class="text-[11px] text-fg-subtle">
                    {String.upcase(evidence.protocol)} via {evidence.source.name} · {ago(
                      evidence.observed_at
                    )}
                  </p>
                </li>
              </ul>
            </section>

            <section id="logical-relationships" class="space-y-2">
              <h2 class="text-xs font-medium text-fg-muted">
                Logical relationships
                <span class="font-mono tabular-nums">{@relationship_count}</span>
              </h2>
              <p class="text-xs text-fg-muted">
                Bonds, bridges, and lower devices reported by hosts. These are not cables.
              </p>
              <ul
                id="relationships-list"
                phx-update="stream"
                class="divide-y divide-edge rounded-lg border border-edge bg-surface"
              >
                <li
                  id="relationships-empty"
                  class="hidden px-3 py-4 text-center text-xs text-fg-muted only:block"
                >
                  No logical relationships.
                </li>
                <li
                  :for={{dom_id, relationship} <- @streams.relationships}
                  id={dom_id}
                  data-relationship-kind={relationship.kind}
                  class="space-y-0.5 px-3 py-2"
                >
                  <.endpoint interface={relationship.source_interface} />
                  <p class="flex items-center gap-1.5 text-xs text-fg-muted">
                    <.icon name="hero-arrow-long-right-mini" class="size-3.5 shrink-0" />
                    <span class="font-mono text-fg">{relationship.target_interface.name}</span>
                    <span>{Format.humanize(relationship.kind)}</span>
                  </p>
                </li>
              </ul>
            </section>
          </aside>
        </div>
      </section>

      <.link_panel
        :if={@selected}
        link={@selected}
        can_manage?={@can_manage?}
        close_path={topology_path(@filters, @link_key, link: nil)}
        link_path={&topology_path(@filters, @link_key, link: &1)}
      />
    </Layouts.app>
    """
  end

  attr :interface, :any, required: true

  defp endpoint(assigns) do
    ~H"""
    <span class="flex min-w-0 items-baseline gap-1.5">
      <span class="shrink-0 font-mono text-sm text-fg">{@interface.name}</span>
      <.link
        navigate={~p"/inventory/#{@interface.resource_id}"}
        class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
      >
        {@interface.resource.name}
      </.link>
    </span>
    """
  end

  attr :link, Links, required: true

  defp layer_marks(assigns) do
    ~H"""
    <span class="inline-flex gap-1 font-mono text-[11px]">
      <span
        :for={{layer, label} <- [plan: "plan", evidence: "seen", cable: "cable"]}
        class={[
          "rounded border px-1",
          if(layer in Links.layers(@link),
            do: "border-edge bg-sunken text-fg",
            else: "border-dashed border-edge text-fg-subtle line-through"
          )
        ]}
      >
        {label}
      </span>
    </span>
    """
  end

  attr :link, Links, required: true
  attr :can_manage?, :boolean, required: true
  attr :close_path, :string, required: true
  attr :link_path, :any, required: true

  defp link_panel(assigns) do
    assigns =
      assign(assigns,
        recordable?:
          is_nil(assigns.link.cable) and
            CableReconciler.physically_connectable?(assigns.link.interface_a) and
            CableReconciler.physically_connectable?(assigns.link.interface_b),
        displaced: Enum.filter(assigns.link.contested, &(:cable in &1.layers))
      )

    ~H"""
    <.side_panel
      id="link-panel"
      title={"#{@link.interface_a.name} ↔ #{@link.interface_b.name}"}
      description={state_description(@link.state)}
      show
      on_cancel={JS.patch(@close_path)}
    >
      <div class="space-y-6">
        <div class="space-y-2">
          <.link_state id="link-panel-state" state={@link.state} />
          <ul class="space-y-1">
            <li :for={interface <- [@link.interface_a, @link.interface_b]}>
              <.endpoint interface={interface} />
            </li>
          </ul>
        </div>

        <section id="link-layers" aria-label="Plan, evidence, and cable record">
          <div class="grid grid-cols-3 gap-2">
            <.layer
              id="link-plan"
              title="Plan"
              icon="hero-pencil-square"
              present={@link.plan}
              absent="Not planned"
            >
              <:line :if={@link.plan}>{@link.plan.cable_type || "Any type"}</:line>
              <:line :if={@link.plan && @link.plan.label}>{@link.plan.label}</:line>
            </.layer>
            <.layer
              id="link-evidence"
              title="Evidence"
              icon="hero-signal"
              present={@link.adjacency}
              absent="Not seen"
            >
              <:line :if={@link.adjacency}>{evidence_summary(@link.adjacency)}</:line>
              <:line :if={@link.adjacency}>
                Seen {ago(@link.adjacency.last_observed_at)}
              </:line>
            </.layer>
            <.layer
              id="link-cable"
              title="Cable record"
              icon="hero-check-badge"
              present={@link.cable}
              absent="Not recorded"
            >
              <:line :if={@link.cable}>{cable_summary(@link.cable)}</:line>
              <:line :if={@link.cable && @link.cable.label}>{@link.cable.label}</:line>
              <:line :if={@link.cable}>
                Recorded {ago(@link.cable.last_asserted_at)}
              </:line>
            </.layer>
          </div>
        </section>

        <section :if={@link.contested != []} id="link-contested" class="space-y-2">
          <h3 class="text-xs font-medium text-fg-muted">Where they disagree</h3>
          <ul class="space-y-1.5">
            <li
              :for={contest <- @link.contested}
              class="rounded-md border border-warn-line bg-warn-fill px-3 py-2 text-xs text-warn-text"
            >
              <span class="font-mono">{contest.interface.name}</span>
              is also connected to
              <.link
                id={"contest-#{contest.key}"}
                patch={@link_path.(contest.key)}
                class="font-medium underline"
              >
                {contest.other.name} on {contest.other.resource.name}
              </.link>
              by {layer_phrase(contest.layers)}
            </li>
          </ul>
        </section>

        <section class="space-y-1.5">
          <h3 class="text-xs font-medium text-fg-muted">Findings</h3>
          <.link
            :for={interface <- [@link.interface_a, @link.interface_b]}
            navigate={~p"/inbox?#{[domain: "topology", interface_id: interface.id]}"}
            class="flex items-center gap-1.5 text-sm text-fg hover:underline"
          >
            <.icon name="hero-inbox" class="size-4 text-fg-subtle" /> Findings on
            <span class="font-mono">{interface.name}</span>
          </.link>
        </section>
      </div>

      <:footer :if={@can_manage? and (@recordable? or @link.cable)}>
        <.button
          :if={@link.cable}
          id="retract-cable"
          variant="danger"
          phx-click={show_overlay("retract-cable-confirm")}
        >
          Retract cable
        </.button>
        <.button
          :if={@recordable?}
          id="record-cable"
          variant="primary"
          phx-click={show_overlay("record-cable-confirm")}
        >
          Record this cable
        </.button>
      </:footer>
    </.side_panel>

    <.confirm_dialog
      :if={@can_manage? and @recordable?}
      id="record-cable-confirm"
      title="Record this cable?"
      confirm_label="Record cable"
      variant="primary"
      on_confirm="record_cable"
    >
      You confirm that a cable connects {@link.interface_a.name} on {@link.interface_a.resource.name} and {@link.interface_b.name} on {@link.interface_b.resource.name}.
      <span :for={contest <- @displaced} class="mt-2 block">
        This replaces the recorded cable from {contest.interface.name} to {contest.other.name} on {contest.other.resource.name}.
      </span>
    </.confirm_dialog>

    <.confirm_dialog
      :if={@can_manage? and @link.cable}
      id="retract-cable-confirm"
      title="Retract this cable?"
      confirm_label="Retract cable"
      on_confirm="retract_cable"
    >
      The cable record between {@link.interface_a.name} and {@link.interface_b.name} is removed. Its history is kept.
    </.confirm_dialog>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :present, :any, required: true
  attr :absent, :string, required: true
  slot :line

  defp layer(assigns) do
    ~H"""
    <div
      id={@id}
      data-present={to_string(not is_nil(@present))}
      class={[
        "min-w-0 space-y-1 rounded-md border p-2.5",
        if(@present, do: "border-edge bg-canvas", else: "border-dashed border-edge")
      ]}
    >
      <p class="flex items-center gap-1 text-[11px] font-medium text-fg-muted">
        <.icon name={@icon} class="size-3.5 shrink-0" />
        <span class="truncate">{@title}</span>
      </p>
      <p :if={!@present} class="text-xs text-fg-subtle">{@absent}</p>
      <p :for={line <- @line} class="text-xs break-words text-fg">{render_slot(line)}</p>
    </div>
    """
  end

  defp evidence_summary(%{primary_evidence: %{protocol: protocol, source: source}} = adjacency) do
    "#{String.upcase(protocol)}, #{adjacency.confidence} via #{source.name}"
  end

  defp evidence_summary(adjacency), do: adjacency.confidence

  defp cable_summary(%{cable_type: type, primary_assertion: %{kind: kind}}),
    do: Enum.join(Enum.reject([type, assertion_source(kind)], &is_nil/1), ", ")

  defp cable_summary(%{cable_type: type}), do: type || "Recorded"

  defp assertion_source("operator"), do: "by an operator"
  defp assertion_source("import"), do: "imported"
  defp assertion_source(_kind), do: nil

  defp layer_phrase(layers) do
    Enum.map_join(layers, " and ", fn
      :plan -> "the plan"
      :evidence -> "the evidence"
      :cable -> "the cable record"
    end)
  end

  defp ago(datetime) do
    case Format.age(datetime) do
      "now" -> "just now"
      age -> "#{age} ago"
    end
  end

  defp link_dom_id(link), do: "link-#{link.key}"

  # Patch paths keep the page's filters; `nil` drops a parameter.
  defp topology_path(filters, link_key, overrides) do
    params =
      [interface_id: filters.interface_id, resource: filters.resource_id, link: link_key]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/network/topology?#{params}"
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
