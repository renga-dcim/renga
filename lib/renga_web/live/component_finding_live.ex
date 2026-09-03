defmodule RengaWeb.ComponentFindingLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Component findings", finding_status: "open")
     |> assign(:finding_filter_form, finding_filter_form("open"))
     |> load_findings("open")}
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"status" => status}}, socket)
      when status in ["open", "resolved"] do
    {:noreply,
     socket
     |> assign(:finding_status, status)
     |> assign(:finding_filter_form, finding_filter_form(status))
     |> load_findings(status)}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:findings}>
      <main id="component-findings" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Reconciliation workspace
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Component findings</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Organization-wide differences between catalog expectations, canonical hardware, and source evidence.
            </p>
          </div>
          <.form
            for={@finding_filter_form}
            id="component-finding-filters"
            phx-change="filter"
          >
            <.input
              field={@finding_filter_form[:status]}
              type="select"
              label="Finding state"
              options={[{"Open", "open"}, {"Resolved", "resolved"}]}
              class="h-10 min-w-40 rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
            />
          </.form>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Visible" value={@finding_count} icon="hero-eye" />
          <.summary_card label="Resources" value={@affected_resource_count} icon="hero-server-stack" />
          <.summary_card
            label="State"
            value={String.capitalize(@finding_status)}
            icon="hero-adjustments-horizontal"
          />
        </section>

        <section
          id="component-findings-list"
          phx-update="stream"
          class="grid gap-4 xl:grid-cols-2"
        >
          <div
            id="component-findings-empty"
            class="hidden rounded-2xl border border-dashed border-base-content/15 bg-base-100 px-6 py-16 text-center only:block xl:col-span-2"
          >
            <.icon name="hero-check-circle" class="mx-auto size-9 text-emerald-500" />
            <h2 class="mt-4 font-semibold">No {@finding_status} component findings</h2>
            <p class="mt-1 text-sm text-base-content/50">
              Reconciliation differences in this organization will appear here.
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
                <p class="text-xs uppercase tracking-wider text-base-content/40">Resource</p>
                <.link
                  navigate={~p"/inventory/resources/#{finding.resource_id}/hardware"}
                  class="mt-1 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
                >
                  {finding.resource.display_name || finding.resource.name}
                  <.icon name="hero-arrow-right" class="size-3.5" />
                </.link>
              </div>
              <div class="text-right">
                <p class="text-xs uppercase tracking-wider text-base-content/40">Last observed</p>
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
                <dt class="text-xs font-semibold capitalize text-base-content/40">{humanize(key)}</dt>
                <dd class="mt-1 break-words font-mono text-xs">{format_value(value)}</dd>
              </div>
            </dl>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp load_findings(socket, status) do
    findings = Catalog.list_organization_component_findings(socket.assigns.current_scope, status)

    socket
    |> assign(:finding_count, length(findings))
    |> assign(:affected_resource_count, findings |> MapSet.new(& &1.resource_id) |> MapSet.size())
    |> stream(:findings, findings,
      reset: true,
      dom_id: &"component-findings-#{&1.id}"
    )
  end

  defp finding_filter_form(status), do: to_form(%{"status" => status}, as: :filters)

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

  defp finding_kind_class(kind) when kind in ["missing_expected_component", "component_drift"] do
    "inline-flex rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-amber-700 dark:text-amber-400"
  end

  defp finding_kind_class(kind)
       when kind in ["unexpected_actual_component", "incompatible_module_type"] do
    "inline-flex rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-rose-700 dark:text-rose-400"
  end

  defp finding_kind_class(_kind) do
    "inline-flex rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-sky-700 dark:text-sky-400"
  end

  defp finding_status_class("open") do
    "rounded-full bg-orange-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-orange-700 dark:text-orange-400"
  end

  defp finding_status_class(_status) do
    "rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55"
  end

  defp humanize(value), do: value |> String.replace("_", " ")
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Renga.JSON.encode!(value)
end
