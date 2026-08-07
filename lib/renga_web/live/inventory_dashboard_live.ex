defmodule RengaWeb.InventoryDashboardLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.AgentLease

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    resources = Inventory.list_operational_resources(scope)
    agents = Inventory.list_agents(scope)

    {:ok,
     assign(socket,
       page_title: "Inventory overview",
       lifecycle_counts: Enum.frequencies_by(resources, & &1.lifecycle_state),
       freshness_counts: freshness_counts(resources),
       connectivity_counts: connectivity_counts(agents),
       resource_count: length(resources),
       agent_count: length(agents)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="inventory-dashboard" class="space-y-8">
        <header class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">
              Operations
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-base-content">
              Inventory overview
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/60">
              Lifecycle intent, reported freshness, and agent connectivity remain independent signals.
            </p>
          </div>
          <p class="text-sm text-base-content/50">{@current_scope.organization.name}</p>
        </header>

        <div id="dashboard-summary" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.metric_card
            id="resource-count"
            label="Resources"
            value={@resource_count}
            detail={count_detail(@lifecycle_counts, "active", "active")}
            icon="hero-server-stack"
            tone="orange"
          />
          <.metric_card
            id="inventory-current-count"
            label="Inventory current"
            value={Map.get(@freshness_counts, :current, 0)}
            detail={count_detail(@freshness_counts, :stale, "stale")}
            icon="hero-circle-stack"
            tone="emerald"
          />
          <.metric_card
            id="agent-connected-count"
            label="Agents connected"
            value={Map.get(@connectivity_counts, :connected, 0)}
            detail={count_detail(@connectivity_counts, :disconnected, "disconnected")}
            icon="hero-signal"
            tone="sky"
          />
          <.metric_card
            id="attention-count"
            label="Needs attention"
            value={
              Map.get(@freshness_counts, :stale, 0) +
                Map.get(@connectivity_counts, :disconnected, 0)
            }
            detail="Across inventory and agents"
            icon="hero-exclamation-triangle"
            tone="amber"
          />
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <.breakdown
            id="lifecycle-breakdown"
            title="Resource lifecycle"
            subtitle="Operator-managed lifecycle intent"
            values={@lifecycle_counts}
            order={["active", "inactive", "retired", "unknown"]}
          />
          <.breakdown
            id="health-breakdown"
            title="Independent health signals"
            subtitle="Observed state, not lifecycle intent"
            values={
              %{
                "inventory current" => Map.get(@freshness_counts, :current, 0),
                "inventory stale" => Map.get(@freshness_counts, :stale, 0),
                "freshness unknown" => Map.get(@freshness_counts, :unknown, 0),
                "agents connected" => Map.get(@connectivity_counts, :connected, 0),
                "agents disconnected" => Map.get(@connectivity_counts, :disconnected, 0)
              }
            }
            order={[
              "inventory current",
              "inventory stale",
              "freshness unknown",
              "agents connected",
              "agents disconnected"
            ]}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :detail, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true

  defp metric_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="group rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:shadow-md"
    >
      <div class="flex items-start justify-between">
        <div>
          <p class="text-sm font-medium text-base-content/55">{@label}</p>
          <p class="mt-3 text-3xl font-semibold tabular-nums tracking-tight">{@value}</p>
        </div>
        <span class={[
          "grid size-10 place-items-center rounded-xl",
          @tone == "orange" && "bg-orange-500/10 text-orange-600",
          @tone == "emerald" && "bg-emerald-500/10 text-emerald-600",
          @tone == "sky" && "bg-sky-500/10 text-sky-600",
          @tone == "amber" && "bg-amber-500/10 text-amber-600"
        ]}>
          <.icon name={@icon} class="size-5" />
        </span>
      </div>
      <p class="mt-4 text-xs text-base-content/50">{@detail}</p>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :values, :map, required: true
  attr :order, :list, required: true

  defp breakdown(assigns) do
    ~H"""
    <section id={@id} class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm">
      <h2 class="font-semibold tracking-tight">{@title}</h2>
      <p class="mt-1 text-sm text-base-content/50">{@subtitle}</p>
      <dl class="mt-6 divide-y divide-base-content/10">
        <div :for={key <- @order} class="flex items-center justify-between py-3 first:pt-0 last:pb-0">
          <dt class="text-sm capitalize text-base-content/65">{key}</dt>
          <dd class="font-mono text-sm font-semibold tabular-nums">{Map.get(@values, key, 0)}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp freshness_counts(resources) do
    resources
    |> Enum.map(fn resource ->
      case Enum.find(resource.conditions, &(&1.type == "InventoryCurrent")) do
        %{status: "true"} -> :current
        %{status: "false"} -> :stale
        _condition -> :unknown
      end
    end)
    |> Enum.frequencies()
  end

  defp connectivity_counts(agents) do
    agents
    |> Enum.map(fn agent ->
      if agent.status == "active" && agent.lease && not AgentLease.expired?(agent.lease) do
        :connected
      else
        :disconnected
      end
    end)
    |> Enum.frequencies()
  end

  defp count_detail(counts, key, label), do: "#{Map.get(counts, key, 0)} #{label}"
end
