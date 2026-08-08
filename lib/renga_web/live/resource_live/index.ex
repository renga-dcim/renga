defmodule RengaWeb.ResourceLive.Index do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Resources")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    stale_only? = params["stale"] == "true"
    page = parse_page(params["page"])

    result =
      Inventory.list_operational_resources(socket.assigns.current_scope,
        stale_only?: stale_only?,
        page: page
      )

    {:noreply,
     socket
     |> assign(:filter_form, to_form(%{"stale" => stale_only?}, as: :filters))
     |> assign(:resources_empty?, result.entries == [])
     |> assign(:stale_only?, stale_only?)
     |> assign(:page, result.page)
     |> assign(:has_next_page?, result.has_next?)
     |> stream(:resources, result.entries, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    path =
      if filters["stale"] == "true" do
        ~p"/inventory/resources?stale=true"
      else
        ~p"/inventory/resources"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="resource-list" class="space-y-6">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">Inventory</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Resources</h1>
            <p class="mt-2 text-sm text-base-content/55">
              Canonical inventory with desired lifecycle and observed health kept distinct.
            </p>
          </div>

          <.form for={@filter_form} id="resource-filters" phx-change="filter">
            <.input
              field={@filter_form[:stale]}
              type="checkbox"
              label="Stale inventory only"
            />
          </.form>
        </header>

        <div class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm">
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-base-content/10 text-left text-sm">
              <thead class="bg-base-200/70 text-xs uppercase tracking-wider text-base-content/45">
                <tr>
                  <th class="px-5 py-3.5 font-semibold">Resource</th>
                  <th class="px-5 py-3.5 font-semibold">Hardware</th>
                  <th class="px-5 py-3.5 font-semibold">Lifecycle</th>
                  <th class="px-5 py-3.5 font-semibold">Conditions</th>
                  <th class="px-5 py-3.5 font-semibold">Provenance</th>
                  <th class="px-5 py-3.5 font-semibold">Last observed</th>
                </tr>
              </thead>
              <tbody id="resources" phx-update="stream" class="divide-y divide-base-content/10">
                <tr :if={@resources_empty?} id="resources-empty">
                  <td colspan="6" class="px-5 py-14 text-center">
                    <.icon name="hero-server-stack" class="mx-auto size-8 text-base-content/25" />
                    <p class="mt-3 font-medium">No resources match this view</p>
                    <p class="mt-1 text-xs text-base-content/45">
                      Inventory appears after an observation is reconciled.
                    </p>
                  </td>
                </tr>
                <tr
                  :for={{id, resource} <- @streams.resources}
                  id={id}
                  class="group transition hover:bg-orange-500/[0.035]"
                >
                  <td class="px-5 py-4">
                    <.link
                      navigate={~p"/inventory/resources/#{resource.id}"}
                      class="font-semibold transition group-hover:text-orange-600"
                    >
                      {resource.display_name || resource.name}
                    </.link>
                    <p class="mt-1 font-mono text-xs uppercase text-base-content/40">
                      {resource.kind}
                    </p>
                  </td>
                  <td class="px-5 py-4">
                    <p class="font-medium">{host_name(resource)}</p>
                    <p class="mt-1 text-xs text-base-content/45">{hardware_name(resource)}</p>
                  </td>
                  <td class="px-5 py-4">
                    <.status_pill label={resource.lifecycle_state} state={resource.lifecycle_state} />
                  </td>
                  <td class="px-5 py-4">
                    <div class="flex max-w-xs flex-wrap gap-1.5">
                      <.condition_pill :for={condition <- resource.conditions} condition={condition} />
                      <span :if={resource.conditions == []} class="text-xs text-base-content/35">
                        Unknown
                      </span>
                    </div>
                  </td>
                  <td class="px-5 py-4">
                    <p class="max-w-48 truncate text-xs text-base-content/60">
                      {source_names(resource)}
                    </p>
                  </td>
                  <td class="px-5 py-4 font-mono text-xs text-base-content/55">
                    {format_time(last_observed_at(resource))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <nav
          :if={@page > 1 or @has_next_page?}
          id="resources-pagination"
          class="flex items-center justify-between"
          aria-label="Resource pages"
        >
          <.link
            :if={@page > 1}
            id="resources-previous"
            patch={pagination_path(@stale_only?, @page - 1)}
            class="rounded-lg border border-base-content/10 px-3 py-2 text-sm font-medium transition hover:border-orange-500/30 hover:text-orange-600"
          >
            Previous
          </.link>
          <span :if={@page == 1} />
          <.link
            :if={@has_next_page?}
            id="resources-next"
            patch={pagination_path(@stale_only?, @page + 1)}
            class="rounded-lg border border-base-content/10 px-3 py-2 text-sm font-medium transition hover:border-orange-500/30 hover:text-orange-600"
          >
            Next
          </.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :state, :string, required: true

  defp status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded-full px-2.5 py-1 text-xs font-medium capitalize",
      @state == "active" && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
      @state == "retired" && "bg-base-content/10 text-base-content/50",
      @state not in ["active", "retired"] && "bg-amber-500/10 text-amber-700 dark:text-amber-400"
    ]}>
      {@label}
    </span>
    """
  end

  attr :condition, :map, required: true

  defp condition_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full border px-2 py-1 text-[11px] font-medium",
      @condition.status == "true" &&
        "border-emerald-500/20 bg-emerald-500/5 text-emerald-700 dark:text-emerald-400",
      @condition.status == "false" &&
        "border-rose-500/20 bg-rose-500/5 text-rose-700 dark:text-rose-400",
      @condition.status == "unknown" && "border-base-content/10 text-base-content/45"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @condition.status == "true" && "bg-emerald-500",
        @condition.status == "false" && "bg-rose-500",
        @condition.status == "unknown" && "bg-base-content/30"
      ]} />
      {@condition.type}
    </span>
    """
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp pagination_path(true, 1), do: ~p"/inventory/resources?stale=true"
  defp pagination_path(true, page), do: ~p"/inventory/resources?stale=true&page=#{page}"
  defp pagination_path(false, 1), do: ~p"/inventory/resources"
  defp pagination_path(false, page), do: ~p"/inventory/resources?page=#{page}"

  defp host_name(%{host: %{hostname: hostname}}) when is_binary(hostname), do: hostname
  defp host_name(resource), do: resource.name

  defp hardware_name(%{host: host}) when not is_nil(host) do
    [host.vendor, host.model]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "Not reported"
      name -> name
    end
  end

  defp hardware_name(_resource), do: "Not reported"

  defp source_names(resource) do
    resource.source_names
    |> Enum.join(", ")
    |> case do
      "" -> "No source evidence"
      names -> names
    end
  end

  defp last_observed_at(resource) do
    resource.last_observed_at
  end

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
