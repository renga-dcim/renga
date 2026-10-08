defmodule RengaWeb.TopologyLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Topology

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Network topology")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    interface_id = blank_to_nil(params["interface_id"])
    interface = interface_id && Inventory.get_interface!(scope, interface_id)

    {:noreply,
     socket
     |> assign(
       interface_id: interface_id,
       interface: interface,
       interface_resource: interface && Inventory.get_resource!(scope, interface.resource_id)
     )
     |> load_topology()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:topology}
    >
      <main id="network-topology" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Layer 2 inventory
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Network topology</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Logical host relationships, reconciled neighbor adjacency, and unresolved
              collector evidence stay distinct so adjacency is never presented as cabling.
            </p>
          </div>
          <div :if={@interface} class="flex flex-col items-start gap-2 lg:items-end">
            <span class="inline-flex items-center gap-2 rounded-lg border border-base-content/15 bg-base-100 px-3 py-2 text-xs font-medium">
              <.icon name="hero-funnel" class="size-3.5 text-base-content/55" />
              <span class="font-mono">{@interface.name}</span>
              <span class="text-base-content/55">· {@interface_resource.name}</span>
            </span>
            <.link
              id="topology-clear-interface"
              navigate={~p"/network/topology"}
              class="inline-flex items-center gap-1 text-xs font-medium text-base-content/55 transition hover:text-orange-600"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Clear interface filter
            </.link>
          </div>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Logical relationships" value={@relationship_count} icon="hero-share" />
          <.summary_card
            label="Reconciled adjacency"
            value={@adjacency_count}
            icon="hero-arrows-right-left"
          />
          <.summary_card label="Unresolved evidence" value={@unresolved_count} icon="hero-signal" />
        </section>

        <section
          id="logical-relationships"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">Logical relationships</h2>
              <p class="mt-1 text-xs text-base-content/55">
                Directed host and stacking topology such as bonds, bridges, and lower devices.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold text-sky-700 dark:text-sky-400">
              Reported structure
            </span>
          </div>

          <ul id="relationships-list" phx-update="stream" class="mt-5 space-y-3">
            <li
              id="relationships-empty"
              class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
            >
              No logical interface relationships in this organization.
            </li>
            <li
              :for={{dom_id, relationship} <- @streams.relationships}
              id={dom_id}
              data-relationship-kind={relationship.kind}
              class="flex flex-col gap-2 rounded-xl bg-base-200/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                <.endpoint_link interface={relationship.source_interface} />
                <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-base-content/50" />
                <.endpoint_link interface={relationship.target_interface} />
              </div>
              <span class="shrink-0 self-start rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55 sm:self-auto">
                {humanize(relationship.kind)}
              </span>
            </li>
          </ul>
        </section>

        <div id="observed-neighbors" class="space-y-7">
          <section
            id="reconciled-adjacency"
            class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="font-semibold tracking-tight">Reconciled adjacency</h2>
                <p class="mt-1 text-xs text-base-content/55">
                  Current Layer 2 neighbors selected from active LLDP/CDP evidence. Adjacency is
                  not proof of physical cabling.
                </p>
              </div>
              <span class="shrink-0 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:text-emerald-400">
                Observed link
              </span>
            </div>

            <ul id="adjacencies-list" phx-update="stream" class="mt-5 space-y-3">
              <li
                id="adjacencies-empty"
                class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
              >
                No reconciled adjacency from active neighbor evidence.
              </li>
              <li
                :for={{dom_id, adjacency} <- @streams.adjacencies}
                id={dom_id}
                data-adjacency-confidence={adjacency.confidence}
                class="flex flex-col gap-3 rounded-xl bg-base-200/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                  <.endpoint_link interface={adjacency.interface_a} />
                  <.icon name="hero-arrows-right-left" class="size-3.5 shrink-0 text-base-content/50" />
                  <.endpoint_link interface={adjacency.interface_b} />
                </div>
                <div class="flex shrink-0 items-center gap-3 self-start sm:self-auto">
                  <span class={confidence_class(adjacency.confidence)}>{adjacency.confidence}</span>
                  <span class="font-mono text-xs text-base-content/60">
                    {format_time(adjacency.last_observed_at)}
                  </span>
                </div>
              </li>
            </ul>
          </section>

          <section
            id="neighbor-evidence"
            class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="font-semibold tracking-tight">Unresolved neighbor evidence</h2>
                <p class="mt-1 text-xs text-base-content/55">
                  Active collector reports whose remote endpoint is not matched to canonical
                  inventory yet. They never create adjacency or cabling on their own.
                </p>
              </div>
              <span class="shrink-0 rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-semibold text-amber-700 dark:text-amber-400">
                Needs matching
              </span>
            </div>

            <ul id="unresolved-evidence-list" phx-update="stream" class="mt-5 space-y-3">
              <li
                id="unresolved-evidence-empty"
                class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
              >
                Every active neighbor report is matched to inventory.
              </li>
              <li
                :for={{dom_id, evidence} <- @streams.unresolved_evidence}
                id={dom_id}
                data-evidence-protocol={evidence.protocol}
                class="rounded-xl bg-base-200/60 px-4 py-3"
              >
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div class="min-w-0">
                    <p class="flex flex-wrap items-center gap-2 text-sm">
                      <.endpoint_link interface={evidence.local_interface} />
                      <span class="font-mono text-xs text-base-content/60">
                        {evidence.protocol} → {evidence.remote_chassis_id}:{evidence.remote_port_id}
                      </span>
                    </p>
                    <p class="mt-1 text-xs text-base-content/60">
                      via {evidence.source.name} · observed {format_time(evidence.observed_at)} · expires {format_time(
                        evidence.expires_at
                      )}
                    </p>
                  </div>
                  <span class="shrink-0 self-start rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55">
                    Unmatched
                  </span>
                </div>
              </li>
            </ul>
          </section>
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp load_topology(socket) do
    scope = socket.assigns.current_scope

    opts =
      if socket.assigns.interface_id,
        do: [interface_id: socket.assigns.interface_id],
        else: []

    relationships = Inventory.list_organization_interface_relationships(scope, opts)
    adjacencies = Topology.list_organization_interface_adjacencies(scope, opts)
    unresolved = Topology.list_unresolved_interface_neighbor_evidence(scope, opts)

    socket
    |> assign(:relationship_count, length(relationships))
    |> assign(:adjacency_count, length(adjacencies))
    |> assign(:unresolved_count, length(unresolved))
    |> stream(:relationships, relationships, dom_id: &"relationship-#{&1.id}", reset: true)
    |> stream(:adjacencies, adjacencies, dom_id: &"adjacency-#{&1.id}", reset: true)
    |> stream(:unresolved_evidence, unresolved,
      dom_id: &"neighbor-evidence-#{&1.id}",
      reset: true
    )
  end

  attr :interface, :any, required: true

  defp endpoint_link(assigns) do
    ~H"""
    <span class="inline-flex min-w-0 items-center gap-1.5">
      <span class="truncate font-mono text-sm font-medium">{@interface.name}</span>
      <.link
        navigate={~p"/inventory/#{@interface.resource_id}"}
        class="truncate text-xs text-base-content/60 transition hover:text-orange-600"
      >
        {@interface.resource.name}
      </.link>
    </span>
    """
  end

  defp confidence_class("reciprocal") do
    "rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:text-emerald-400"
  end

  defp confidence_class(_confidence) do
    "rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55"
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

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp humanize(value), do: value |> String.replace("_", " ")
  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
