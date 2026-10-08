defmodule RengaWeb.TopologyFindingLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Topology

  @statuses ~w(open resolved)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Topology findings")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = normalize_status(params["status"])
    kind = params["kind"] |> blank_to_nil() |> normalize_kind()
    interface_id = blank_to_nil(params["interface_id"])

    {:noreply,
     socket
     |> assign(
       finding_status: status,
       finding_kind: kind,
       interface_id: interface_id,
       filter_form: to_form(%{"status" => status, "kind" => kind || "all"}, as: :filters),
       kind_options: kind_options()
     )
     |> load_findings()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         findings_path(socket,
           status: normalize_status(params["status"]),
           kind: blank_to_nil(params["kind"]) |> normalize_kind()
         )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:topology_findings}
    >
      <main id="topology-findings" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Reconciliation workspace
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Topology findings</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              VLAN membership, neighbor adjacency, and cabling differences between intent,
              claims, and observed reality. Findings explain disagreement; they never change it.
            </p>
          </div>
          <.form
            for={@filter_form}
            id="topology-finding-filters"
            phx-change="filter"
            class="flex flex-wrap items-end gap-4"
          >
            <.input
              field={@filter_form[:status]}
              type="select"
              label="Finding state"
              options={[{"Open", "open"}, {"Resolved", "resolved"}]}
              class={input_class()}
            />
            <.input
              field={@filter_form[:kind]}
              type="select"
              label="Kind"
              options={@kind_options}
              class={input_class()}
            />
          </.form>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Visible" value={@finding_count} icon="hero-eye" />
          <.summary_card
            label="Interfaces"
            value={@affected_interface_count}
            icon="hero-server-stack"
          />
          <.summary_card
            label="State"
            value={String.capitalize(@finding_status)}
            icon="hero-adjustments-horizontal"
          />
        </section>

        <section id="topology-findings-list" phx-update="stream" class="grid gap-4 xl:grid-cols-2">
          <div
            id="topology-findings-empty"
            class="hidden rounded-2xl border border-dashed border-base-content/15 bg-base-100 px-6 py-16 text-center only:block xl:col-span-2"
          >
            <.icon name="hero-check-circle" class="mx-auto size-9 text-emerald-500" />
            <h2 class="mt-4 font-semibold">No {@finding_status} topology findings</h2>
            <p class="mt-1 text-sm text-base-content/55">
              VLAN, adjacency, and cabling differences in this organization will appear here.
            </p>
          </div>

          <article
            :for={{dom_id, finding} <- @streams.findings}
            id={dom_id}
            data-finding-kind={finding.kind}
            class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm transition hover:border-orange-500/25 hover:shadow-md"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <span class={finding_kind_class(finding.kind)}>{humanize(finding.kind)}</span>
                <h2 class="mt-3 text-lg font-semibold tracking-tight">{finding.message}</h2>
              </div>
              <span class={finding_status_class(finding.status)}>{finding.status}</span>
            </div>

            <div class="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-base-content/10 pt-4">
              <div>
                <p class="text-xs uppercase tracking-wider text-base-content/55">Interface</p>
                <.link
                  navigate={~p"/inventory/#{finding.interface.resource_id}"}
                  class="mt-1 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
                >
                  <span class="font-mono">{finding.interface.name}</span>
                  <span class="text-xs font-normal text-base-content/55">
                    · {finding.interface.resource.name}
                  </span>
                  <.icon name="hero-arrow-right" class="size-3.5" />
                </.link>
              </div>
              <div class="text-right">
                <p class="text-xs uppercase tracking-wider text-base-content/55">Last observed</p>
                <p class="mt-1 font-mono text-xs text-base-content/55">
                  {format_time(finding.last_observed_at)}
                </p>
              </div>
            </div>

            <dl
              :if={finding.details != %{}}
              class="mt-4 grid gap-2 rounded-xl bg-base-200/55 p-4 sm:grid-cols-2"
            >
              <div :for={{key, value} <- Enum.sort(finding.details)}>
                <dt class="text-xs font-semibold capitalize text-base-content/55">{humanize(key)}</dt>
                <dd class="mt-1 break-words font-mono text-xs">{format_value(value)}</dd>
              </div>
            </dl>

            <p :if={finding.resolved_at} class="mt-4 text-xs text-base-content/55">
              Resolved {format_time(finding.resolved_at)}
            </p>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp load_findings(socket) do
    scope = socket.assigns.current_scope

    opts =
      [
        status: socket.assigns.finding_status,
        kind: socket.assigns.finding_kind,
        interface_id: socket.assigns.interface_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    findings = Topology.list_organization_topology_findings(scope, opts)

    socket
    |> assign(:finding_count, length(findings))
    |> assign(
      :affected_interface_count,
      findings |> MapSet.new(& &1.interface_id) |> MapSet.size()
    )
    |> stream(:findings, findings, dom_id: &"topology-finding-#{&1.id}", reset: true)
  end

  defp kind_options do
    [{"All kinds", "all"}] ++
      Enum.map(Topology.topology_finding_kinds(), &{humanize(&1), &1})
  end

  defp findings_path(socket, overrides) do
    params =
      %{
        "status" => socket.assigns.finding_status,
        "kind" => socket.assigns.finding_kind,
        "interface_id" => socket.assigns.interface_id
      }
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/inbox/topology?#{params}"
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_status), do: "open"

  defp normalize_kind("all"), do: nil
  defp normalize_kind(kind), do: kind

  defp finding_kind_class(kind) when kind in ["cable_plan_conflict", "cable_endpoint_conflict"] do
    "inline-flex rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-rose-700 dark:text-rose-400"
  end

  defp finding_kind_class(kind)
       when kind in [
              "cable_plan_infeasible",
              "cable_plan_drift",
              "cable_endpoint_infeasible",
              "cable_neighbor_mismatch"
            ] do
    "inline-flex rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-amber-700 dark:text-amber-400"
  end

  defp finding_kind_class(kind) when kind in ["conflicting_neighbors", "asymmetric_neighbor"] do
    "inline-flex rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-rose-700 dark:text-rose-400"
  end

  defp finding_kind_class(_kind) do
    "inline-flex rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-sky-700 dark:text-sky-400"
  end

  defp finding_status_class("open") do
    "shrink-0 rounded-full bg-orange-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-orange-700 dark:text-orange-400"
  end

  defp finding_status_class(_status) do
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
    "h-10 min-w-40 rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp humanize(value), do: value |> String.replace("_", " ")
  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Renga.JSON.encode!(value)
end
