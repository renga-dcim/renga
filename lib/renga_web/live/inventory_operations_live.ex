defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.AgentLease

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sources and agents")
     |> stream_configure(:sources, dom_id: &source_dom_id/1)
     |> schedule_refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    disconnected_only? = params["disconnected"] == "true"

    {:noreply,
     socket
     |> assign(:disconnected_only?, disconnected_only?)
     |> assign(:filter_form, to_form(%{"disconnected" => disconnected_only?}, as: :filters))
     |> load_operations()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    path =
      if filters["disconnected"] == "true" do
        ~p"/inventory/operations?disconnected=true"
      else
        ~p"/inventory/operations"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load_operations() |> schedule_refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="source-list" class="space-y-8">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">
              Collection plane
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Sources and agents</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Credential state, inventory recency, and runtime lease health are reported independently.
            </p>
          </div>
          <.form for={@filter_form} id="agent-filters" phx-change="filter">
            <.input
              field={@filter_form[:disconnected]}
              type="checkbox"
              label="Disconnected agents only"
            />
          </.form>
        </header>

        <section aria-labelledby="sources-heading" class="space-y-4">
          <div class="flex items-center justify-between">
            <div>
              <h2 id="sources-heading" class="text-lg font-semibold tracking-tight">
                Reporting sources
              </h2>
              <p class="mt-1 text-xs text-base-content/45">
                Authentication authorities and provenance anchors
              </p>
            </div>
          </div>

          <div id="sources" phx-update="stream" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <div
              :if={@sources_empty?}
              id="sources-empty"
              class="col-span-full rounded-2xl border border-dashed border-base-content/15 p-10 text-center text-sm text-base-content/45"
            >
              No reporting sources registered.
            </div>
            <article
              :for={{id, source} <- @streams.sources}
              id={id}
              class="rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:shadow-md"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-semibold">{source.name}</p>
                  <p class="mt-1 font-mono text-xs uppercase text-base-content/40">
                    {humanize(source.kind)}
                  </p>
                </div>
                <.state_pill state={source.status} />
              </div>

              <dl class="mt-6 grid grid-cols-2 gap-4 border-t border-base-content/10 pt-4">
                <div>
                  <dt class="text-[11px] uppercase tracking-wider text-base-content/40">
                    Credential
                  </dt>
                  <dd class="mt-1 text-xs font-medium">{credential_state(source)}</dd>
                </div>
                <div>
                  <dt class="text-[11px] uppercase tracking-wider text-base-content/40">Agents</dt>
                  <dd class="mt-1 font-mono text-xs font-semibold">{length(source.agents)}</dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-[11px] uppercase tracking-wider text-base-content/40">
                    Last inventory
                  </dt>
                  <dd class="mt-1 font-mono text-xs text-base-content/65">
                    {format_time(Map.get(@last_inventory_by_source, source.id))}
                  </dd>
                </div>
              </dl>
            </article>
          </div>
        </section>

        <section aria-labelledby="agents-heading" class="space-y-4">
          <div>
            <h2 id="agents-heading" class="text-lg font-semibold tracking-tight">
              Registered agents
            </h2>
            <p class="mt-1 text-xs text-base-content/45">
              Runtime installations and renewable connectivity leases
            </p>
          </div>

          <div class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm">
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-base-content/10 text-left text-sm">
                <thead class="bg-base-200/70 text-xs uppercase tracking-wider text-base-content/45">
                  <tr>
                    <th class="px-5 py-3.5 font-semibold">Agent</th>
                    <th class="px-5 py-3.5 font-semibold">Source</th>
                    <th class="px-5 py-3.5 font-semibold">Lease health</th>
                    <th class="px-5 py-3.5 font-semibold">Capabilities</th>
                    <th class="px-5 py-3.5 font-semibold">Last inventory</th>
                  </tr>
                </thead>
                <tbody id="agents" phx-update="stream" class="divide-y divide-base-content/10">
                  <tr :if={@agents_empty?} id="agents-empty">
                    <td colspan="5" class="px-5 py-12 text-center text-sm text-base-content/45">
                      No agents match this view.
                    </td>
                  </tr>
                  <tr
                    :for={{id, agent} <- @streams.agents}
                    id={id}
                    class="transition hover:bg-orange-500/[0.035]"
                  >
                    <td class="px-5 py-4">
                      <p class="font-semibold">{agent.name}</p>
                      <p class="mt-1 font-mono text-xs text-base-content/40">
                        v{agent.version || "unknown"}
                      </p>
                    </td>
                    <td class="px-5 py-4">
                      <p>{agent.source.name}</p>
                      <p class="mt-1 text-xs capitalize text-base-content/40">
                        {humanize(agent.source.kind)}
                      </p>
                    </td>
                    <td class="px-5 py-4">
                      <.lease_pill agent={agent} />
                      <p class="mt-1.5 font-mono text-[11px] text-base-content/40">
                        {lease_expiry(agent.lease)}
                      </p>
                    </td>
                    <td class="px-5 py-4">
                      <div class="flex max-w-sm flex-wrap gap-1.5">
                        <span
                          :for={capability <- agent.capabilities}
                          class="rounded-md bg-base-200 px-2 py-1 font-mono text-[11px]"
                        >
                          {capability}
                        </span>
                        <span :if={agent.capabilities == []} class="text-xs text-base-content/35">
                          None reported
                        </span>
                      </div>
                    </td>
                    <td class="px-5 py-4 font-mono text-xs text-base-content/55">
                      {format_time(Map.get(@last_inventory_by_source, agent.source_id))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :state, :string, required: true

  defp state_pill(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2.5 py-1 text-xs font-medium capitalize",
      @state == "active" && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
      @state != "active" && "bg-rose-500/10 text-rose-700 dark:text-rose-400"
    ]}>
      {@state}
    </span>
    """
  end

  attr :agent, :map, required: true

  defp lease_pill(assigns) do
    connected? = not disconnected?(assigns.agent)
    assigns = assign(assigns, :connected?, connected?)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
      @connected? && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
      not @connected? && "bg-rose-500/10 text-rose-700 dark:text-rose-400"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @connected? && "bg-emerald-500",
        not @connected? && "bg-rose-500"
      ]} />
      {if(@connected?, do: "Connected", else: "Disconnected")}
    </span>
    """
  end

  defp disconnected?(agent) do
    agent.status != "active" || is_nil(agent.lease) || AgentLease.expired?(agent.lease)
  end

  defp credential_state(%{status: "active", token_hash: token_hash}) when not is_nil(token_hash),
    do: "Issued"

  defp credential_state(%{status: "active"}), do: "Not issued"
  defp credential_state(_source), do: "Revoked"

  defp load_operations(socket) do
    scope = socket.assigns.current_scope
    sources = Inventory.list_operational_sources(scope)
    agents = Inventory.list_agents(scope)

    agents =
      if socket.assigns.disconnected_only?,
        do: Enum.filter(agents, &disconnected?/1),
        else: agents

    socket
    |> assign(:last_inventory_by_source, Inventory.latest_observation_times(scope))
    |> assign(:sources_empty?, sources == [])
    |> assign(:agents_empty?, agents == [])
    |> stream(:sources, sources, reset: true)
    |> stream(:agents, agents, reset: true)
  end

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  defp source_dom_id(source), do: "source-#{source.id}"

  defp lease_expiry(nil), do: "No lease"
  defp lease_expiry(lease), do: "expires #{format_time(lease.expires_at)}"

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp humanize(value), do: String.replace(value, "_", " ")
end
