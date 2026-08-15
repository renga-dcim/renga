defmodule RengaWeb.ResourceLive.Index do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory

  @condition_options [
    {"Any condition", ""},
    {"Inventory current", "InventoryCurrent"},
    {"Agent connected", "AgentConnected"},
    {"Ready", "Ready"},
    {"Degraded", "Degraded"},
    {"Reconciling", "Reconciling"}
  ]
  @lifecycle_options [
    {"Any lifecycle", ""},
    {"Active", "active"},
    {"Inactive", "inactive"},
    {"Retired", "retired"},
    {"Unknown", "unknown"}
  ]
  @lifecycle_edit_options [
    {"Active — in service", "active"},
    {"Inactive — out of service", "inactive"},
    {"Retired — no longer used", "retired"},
    {"Unknown — not classified", "unknown"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    sources = Inventory.list_sources(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       page_title: "Resources",
       lifecycle_options: @lifecycle_options,
       lifecycle_edit_options: @lifecycle_edit_options,
       can_manage_lifecycle?: Inventory.organization_manager?(socket.assigns.current_scope),
       condition_options: @condition_options,
       source_options: [{"Any source", ""} | Enum.map(sources, &{&1.name, &1.id})]
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    result = list_resources(socket.assigns.current_scope, filters)

    selected_resource =
      case params["selected"] do
        id when is_binary(id) and id != "" ->
          Inventory.get_operational_resource!(socket.assigns.current_scope, id)

        _none ->
          nil
      end

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filter_form_params(filters), as: :filters))
     |> assign(:resources_empty?, result.entries == [])
     |> assign(:page, result.page)
     |> assign(:has_next_page?, result.has_next?)
     |> assign(:resource_count, result.total)
     |> assign(:selected_resource, selected_resource)
     |> assign(:lifecycle_form, lifecycle_form(selected_resource))
     |> stream(:resources, result.entries, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      socket.assigns.filters
      | search: String.trim(params["search"] || ""),
        lifecycle: params["lifecycle"] || "",
        condition: params["condition"] || "",
        source_id: params["source_id"] || "",
        page: 1
    }

    {:noreply, push_patch(socket, to: workspace_path(filters, selected_id(socket)))}
  end

  def handle_event("refresh", _params, socket) do
    result = list_resources(socket.assigns.current_scope, socket.assigns.filters)

    {:noreply,
     socket
     |> assign(:resources_empty?, result.entries == [])
     |> assign(:has_next_page?, result.has_next?)
     |> assign(:resource_count, result.total)
     |> stream(:resources, result.entries, reset: true)}
  end

  def handle_event("clear_stale", _params, socket) do
    filters = %{socket.assigns.filters | stale_only?: false, page: 1}
    {:noreply, push_patch(socket, to: workspace_path(filters, selected_id(socket)))}
  end

  def handle_event(
        "update_lifecycle",
        %{"lifecycle" => %{"lifecycle_state" => _lifecycle_state}},
        %{assigns: %{selected_resource: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event(
        "update_lifecycle",
        %{"lifecycle" => %{"lifecycle_state" => lifecycle_state}},
        socket
      ) do
    resource = socket.assigns.selected_resource

    case Inventory.update_resource_lifecycle(
           socket.assigns.current_scope,
           resource,
           lifecycle_state
         ) do
      {:ok, _resource} ->
        {:noreply,
         socket
         |> put_flash(:info, "Resource lifecycle updated")
         |> reload_workspace_resource(resource.id)}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "Resource changed elsewhere; review the latest lifecycle and retry")
         |> reload_workspace_resource(resource.id)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage resource lifecycle")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Select a valid lifecycle state")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:resources}
      content_class="p-0"
    >
      <section id="resource-list" class="flex h-full min-h-0 flex-col">
        <header class="flex h-[104px] shrink-0 items-end justify-between border-b border-base-content/10 px-4 pb-4 sm:px-6">
          <div>
            <p class="text-[11px] text-base-content/45">
              {@current_scope.organization.name} <span class="px-1.5">/</span> Resources
            </p>
            <div class="mt-3 flex items-center gap-2.5">
              <h1 class="text-xl font-semibold tracking-tight">Resources</h1>
              <span
                id="resource-count"
                class="rounded-md bg-base-content/[0.06] px-2 py-0.5 font-mono text-[11px] text-base-content/55"
              >
                {@resource_count}
              </span>
            </div>
          </div>
          <div class="flex items-center gap-1">
            <button
              id="refresh-resources"
              type="button"
              phx-click="refresh"
              class="inline-flex h-8 items-center gap-1.5 rounded-md px-2.5 text-xs text-base-content/55 transition hover:bg-base-content/[0.05] hover:text-base-content"
            >
              <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
            </button>
          </div>
        </header>

        <.form
          for={@filter_form}
          id="resource-filters"
          phx-change="filter"
          class="flex h-[70px] shrink-0 items-center gap-2 overflow-x-auto border-b border-base-content/10 px-4 sm:px-6 [&_.fieldset]:!mb-0"
        >
          <div class="relative min-w-52 flex-1">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-2.5 z-10 size-4 text-base-content/35"
            />
            <.input
              field={@filter_form[:search]}
              type="search"
              placeholder="Search resources..."
              autocomplete="off"
              phx-debounce="250"
              class="h-9 w-full rounded-md border border-base-content/10 bg-base-100 py-0 pl-9 pr-3 text-xs outline-none transition placeholder:text-base-content/30 focus:border-orange-600/50"
            />
          </div>
          <.input
            field={@filter_form[:lifecycle]}
            type="select"
            options={@lifecycle_options}
            class="h-9 rounded-md border border-base-content/10 bg-base-100 px-2.5 text-xs outline-none transition focus:border-orange-600/50"
          />
          <.input
            field={@filter_form[:condition]}
            type="select"
            options={@condition_options}
            class="h-9 rounded-md border border-base-content/10 bg-base-100 px-2.5 text-xs outline-none transition focus:border-orange-600/50"
          />
          <.input
            field={@filter_form[:source_id]}
            type="select"
            options={@source_options}
            class="h-9 rounded-md border border-base-content/10 bg-base-100 px-2.5 text-xs outline-none transition focus:border-orange-600/50"
          />
          <button
            :if={@filters.stale_only?}
            id="clear-stale-filter"
            type="button"
            phx-click="clear_stale"
            class="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-md border border-amber-500/25 px-2.5 text-xs text-amber-700 transition hover:bg-amber-500/5 dark:text-amber-400"
            aria-label="Clear stale inventory filter"
          >
            <span class="size-1.5 rounded-full bg-amber-500" /> Stale only
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </.form>

        <div class="flex min-h-0 flex-1">
          <div class="min-w-0 flex-1 overflow-auto">
            <table class="w-full min-w-[1100px] table-fixed text-left text-xs">
              <thead class="sticky top-0 z-10 border-b border-base-content/10 bg-base-200/70 text-[10px] font-semibold uppercase tracking-[0.08em] text-base-content/40 backdrop-blur-sm">
                <tr class="h-9">
                  <th class="w-[22%] px-4 font-semibold">Resource</th>
                  <th class="w-[22%] px-3 font-semibold">Hardware</th>
                  <th class="w-[10%] px-3 font-semibold">Lifecycle</th>
                  <th class="w-[14%] px-3 font-semibold">Conditions</th>
                  <th class="w-[18%] px-3 font-semibold">Source</th>
                  <th class="w-[14%] px-3 font-semibold">Observed</th>
                </tr>
              </thead>
              <tbody id="resources" phx-update="stream" class="divide-y divide-base-content/[0.07]">
                <tr :if={@resources_empty?} id="resources-empty">
                  <td colspan="6" class="px-5 py-16 text-center text-base-content/45">
                    <.icon name="hero-cube" class="mx-auto size-6" />
                    <p class="mt-2 text-xs font-medium text-base-content/65">No resources match</p>
                    <p class="mt-1 text-[11px]">Try removing one or more filters.</p>
                  </td>
                </tr>
                <tr
                  :for={{id, resource} <- @streams.resources}
                  id={id}
                  class={[
                    "group h-10 transition hover:bg-base-content/[0.025]",
                    selected?(@selected_resource, resource) &&
                      "bg-orange-500/[0.055] shadow-[inset_2px_0_0_0] shadow-orange-600"
                  ]}
                >
                  <td
                    class="truncate px-4"
                    title={
                      "#{resource.display_name || resource.name} · #{humanize(resource.kind)}"
                    }
                  >
                    <.link
                      patch={workspace_path(@filters, resource.id)}
                      class="block truncate font-medium outline-none group-hover:text-base-content focus:text-orange-600"
                    >
                      {resource.display_name || resource.name}
                      <span class="ml-1 font-normal text-base-content/35">
                        · {humanize(resource.kind)}
                      </span>
                    </.link>
                  </td>
                  <td
                    class="truncate px-3 text-base-content/60"
                    title={hardware_name(resource)}
                  >
                    {hardware_name(resource)}
                  </td>
                  <td class="px-3">
                    <span class="inline-flex items-center gap-1.5 capitalize text-base-content/65">
                      <span class={lifecycle_dot(resource.lifecycle_state)} />
                      {resource.lifecycle_state}
                    </span>
                  </td>
                  <td class="truncate px-3" title={condition_summary(resource.conditions)}>
                    <span class="inline-flex max-w-full items-center gap-1.5 text-base-content/60">
                      <span class={condition_dot(resource.conditions)} />
                      <span class="truncate">{condition_summary(resource.conditions)}</span>
                    </span>
                  </td>
                  <td class="truncate px-3 text-base-content/55" title={source_names(resource)}>
                    <span class="inline-flex max-w-full items-center gap-1.5">
                      <.icon name="hero-circle-stack" class="size-3.5 shrink-0 text-base-content/35" />
                      <span class="truncate">{source_names(resource)}</span>
                    </span>
                  </td>
                  <td
                    class="truncate px-3 font-mono text-[10px] text-base-content/45"
                    title={format_time(last_observed_at(resource))}
                  >
                    {format_time(last_observed_at(resource))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <.resource_panel
            :if={@selected_resource}
            resource={@selected_resource}
            close_path={workspace_path(@filters, nil)}
            lifecycle_form={@lifecycle_form}
            lifecycle_options={@lifecycle_edit_options}
            can_manage_lifecycle?={@can_manage_lifecycle?}
          />
        </div>

        <nav
          :if={@page > 1 or @has_next_page?}
          id="resources-pagination"
          class="flex h-11 shrink-0 items-center justify-between border-t border-base-content/10 px-4 text-xs"
          aria-label="Resource pages"
        >
          <.link
            :if={@page > 1}
            id="resources-previous"
            patch={workspace_path(%{@filters | page: @page - 1}, selected_id(assigns))}
            class="rounded-md px-2.5 py-1.5 text-base-content/55 transition hover:bg-base-content/[0.05] hover:text-base-content"
          >
            Previous
          </.link>
          <span :if={@page == 1} />
          <span class="font-mono text-[10px] text-base-content/35">Page {@page}</span>
          <.link
            :if={@has_next_page?}
            id="resources-next"
            patch={workspace_path(%{@filters | page: @page + 1}, selected_id(assigns))}
            class="rounded-md px-2.5 py-1.5 text-base-content/55 transition hover:bg-base-content/[0.05] hover:text-base-content"
          >
            Next
          </.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  attr :resource, :map, required: true
  attr :close_path, :string, required: true
  attr :lifecycle_form, :map, required: true
  attr :lifecycle_options, :list, required: true
  attr :can_manage_lifecycle?, :boolean, required: true

  defp resource_panel(assigns) do
    ~H"""
    <aside
      id="resource-detail-panel"
      phx-hook="ResizablePanel"
      data-narrow-layout="overlay"
      class="fixed inset-0 z-30 w-full shrink-0 overflow-hidden border-l border-base-content/10 bg-base-100 lg:relative lg:inset-auto lg:z-auto lg:w-96 lg:bg-base-200/25"
    >
      <div
        id="resource-detail-resize-handle"
        data-resize-handle
        role="separator"
        tabindex="0"
        aria-label="Resize detail panel"
        aria-orientation="vertical"
        aria-valuemin="384"
        aria-valuemax="768"
        aria-valuenow="384"
        class="group absolute inset-y-0 left-0 z-20 hidden w-2 touch-none cursor-col-resize items-center justify-center outline-none lg:flex"
      >
        <span class="h-12 w-0.5 rounded-full bg-base-content/10 transition group-hover:bg-orange-500/50 group-focus:bg-orange-500/70" />
      </div>
      <div class="h-full overflow-y-auto">
        <header class="border-b border-base-content/10 px-5 pb-4 pt-5">
          <div class="flex items-start justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <.icon name="hero-server-stack" class="size-7 shrink-0 text-base-content/55" />
              <div class="min-w-0">
                <h2
                  class="truncate text-lg font-semibold tracking-tight"
                  title={@resource.display_name || @resource.name}
                >
                  {@resource.display_name || @resource.name}
                </h2>
                <p class="mt-1 text-[10px] uppercase tracking-[0.1em] text-base-content/40">
                  {@resource.kind}
                  <%= if !@can_manage_lifecycle? do %>
                    <span class="px-1">·</span> {@resource.lifecycle_state}
                  <% end %>
                </p>
              </div>
            </div>
            <div class="flex items-center">
              <button
                id="resource-detail-expand"
                type="button"
                data-expand-panel
                aria-label="Expand detail panel"
                aria-pressed="false"
                class="hidden rounded-md p-1.5 text-base-content/40 transition hover:bg-base-content/[0.05] hover:text-base-content lg:block"
              >
                <.icon name="hero-arrows-pointing-out" class="size-4" />
              </button>
              <.link
                navigate={~p"/inventory/resources/#{@resource.id}"}
                class="rounded-md p-1.5 text-base-content/40 transition hover:bg-base-content/[0.05] hover:text-base-content"
                aria-label="Open full resource page"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              </.link>
              <.link
                patch={@close_path}
                class="rounded-md p-1.5 text-base-content/40 transition hover:bg-base-content/[0.05] hover:text-base-content"
                aria-label="Close resource details"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </.link>
            </div>
          </div>

          <div class="mt-5 grid grid-cols-3 gap-2">
            <.status_summary
              label="Inventory"
              condition={find_condition(@resource, "InventoryCurrent")}
            />
            <.status_summary
              label="Reachable"
              condition={find_condition(@resource, "AgentConnected")}
            />
            <div class="rounded-md border border-base-content/10 px-2.5 py-2">
              <p class="text-[9px] text-base-content/40">Observed</p>
              <p
                class="mt-1 truncate font-mono text-[10px] text-base-content/70"
                title={format_time(@resource.last_observed_at)}
              >
                {format_time(@resource.last_observed_at)}
              </p>
            </div>
          </div>

          <div class="mt-4 flex flex-wrap items-start justify-between gap-x-6 gap-y-3 border-t border-base-content/10 pt-4">
            <div class="min-w-48 flex-1">
              <p class="text-[10px] font-semibold uppercase tracking-[0.1em] text-base-content/45">
                Inventory lifecycle
              </p>
              <p
                id="resource-panel-lifecycle-help"
                class="mt-1 max-w-md text-[11px] leading-4 text-base-content/45"
              >
                Classifies this resource for planning and filters. It does not control the device or
                reflect agent connectivity.
              </p>
            </div>
            <.form
              :if={@can_manage_lifecycle?}
              for={@lifecycle_form}
              id="resource-panel-lifecycle-form"
              phx-submit="update_lifecycle"
              class="flex w-72 shrink-0 items-start gap-2"
            >
              <div class="min-w-0 flex-1">
                <.input
                  field={@lifecycle_form[:lifecycle_state]}
                  type="select"
                  aria-label="Lifecycle state"
                  aria-describedby="resource-panel-lifecycle-help"
                  options={@lifecycle_options}
                  class="h-9 w-full rounded-lg border border-base-content/15 bg-base-100 px-2.5 text-xs font-medium capitalize outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
                />
              </div>
              <button
                id="resource-panel-lifecycle-save"
                type="submit"
                phx-disable-with="Saving…"
                class="h-9 rounded-lg bg-orange-500 px-3 text-xs font-semibold text-white transition hover:bg-orange-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
              >
                Save
              </button>
            </.form>
            <span
              :if={!@can_manage_lifecycle?}
              class="rounded-full border border-base-content/15 px-3 py-1.5 text-xs font-semibold capitalize text-base-content/55"
            >
              {@resource.lifecycle_state}
            </span>
          </div>
        </header>

        <div class="border-b border-base-content/10 px-5">
          <span class="inline-flex h-10 items-center border-b-2 border-orange-600 text-xs font-medium">
            Details
          </span>
          <span class="ml-5 inline-flex h-10 items-center text-xs text-base-content/40">
            Activity
          </span>
        </div>

        <div class="divide-y divide-base-content/10 px-5">
          <.detail_section title="Canonical projection">
            <.detail_row label="FQDN" value={host_field(@resource, :fqdn)} />
            <.detail_row label="Vendor" value={host_field(@resource, :vendor)} />
            <.detail_row label="Model" value={host_field(@resource, :model)} />
            <.detail_row label="Asset tag" value={host_field(@resource, :asset_tag)} />
          </.detail_section>

          <.detail_section title="Network">
            <.detail_row label="Interface" value={interface_field(@resource, :name)} />
            <.detail_row label="IP address" value={primary_address(@resource)} />
            <.detail_row label="MAC address" value={interface_field(@resource, :mac_address)} />
          </.detail_section>

          <.detail_section title="Provenance">
            <.detail_row label="Sources" value={source_names(@resource)} />
            <.detail_row label="Generation" value={to_string(@resource.generation)} />
            <.detail_row label="Identifiers" value={to_string(length(@resource.identifiers))} />
          </.detail_section>

          <.detail_section title="Recent changes">
            <ol id="panel-change-events" class="space-y-3">
              <li :for={event <- Enum.take(@resource.change_events, 5)} class="flex gap-2.5">
                <span class="mt-1 size-1.5 shrink-0 rounded-full bg-base-content/30" />
                <div class="min-w-0">
                  <p class="break-words text-[11px] font-medium capitalize">
                    {humanize(event.kind)}
                  </p>
                  <p class="mt-0.5 break-words text-[10px] text-base-content/40">
                    {event.field || "Resource"} · {format_time(event.occurred_at)}
                  </p>
                </div>
              </li>
              <li :if={@resource.change_events == []} class="text-[11px] text-base-content/40">
                No changes recorded.
              </li>
            </ol>
          </.detail_section>
        </div>
      </div>
    </aside>
    """
  end

  attr :label, :string, required: true
  attr :condition, :map, default: nil

  defp status_summary(assigns) do
    ~H"""
    <div class="rounded-md border border-base-content/10 px-2.5 py-2">
      <p class="text-[9px] text-base-content/40">{@label}</p>
      <p
        class="mt-1 flex items-center gap-1.5 truncate text-[10px] text-base-content/70"
        title={condition_value(@condition)}
      >
        <span class={condition_status_dot(@condition)} />
        {condition_value(@condition)}
      </p>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp detail_section(assigns) do
    ~H"""
    <section class="py-5">
      <h3 class="text-[10px] font-semibold uppercase tracking-[0.1em] text-base-content/45">
        {@title}
      </h3>
      <dl class="mt-3 space-y-2.5">{render_slot(@inner_block)}</dl>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail_row(assigns) do
    ~H"""
    <div class="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-3 text-[11px]">
      <dt class="text-base-content/40">{@label}</dt>
      <dd class="min-w-0 select-text break-words text-base-content/75">{@value}</dd>
    </div>
    """
  end

  defp parse_filters(params) do
    %{
      search: String.trim(params["q"] || ""),
      lifecycle: params["lifecycle"] || "",
      condition: params["condition"] || "",
      source_id: params["source"] || "",
      stale_only?: params["stale"] == "true",
      page: parse_page(params["page"])
    }
  end

  defp filter_form_params(filters) do
    %{
      "search" => filters.search,
      "lifecycle" => filters.lifecycle,
      "condition" => filters.condition,
      "source_id" => filters.source_id
    }
  end

  defp list_resources(scope, filters) do
    Inventory.list_operational_resources(scope,
      search: filters.search,
      lifecycle: filters.lifecycle,
      condition: filters.condition,
      source_id: filters.source_id,
      stale_only?: filters.stale_only?,
      page: filters.page
    )
  end

  defp workspace_path(filters, selected_id) do
    query =
      %{
        "q" => filters.search,
        "lifecycle" => filters.lifecycle,
        "condition" => filters.condition,
        "source" => filters.source_id,
        "stale" => filters.stale_only? && "true",
        "page" => filters.page > 1 && filters.page,
        "selected" => selected_id
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)
      |> Map.new()

    ~p"/inventory/resources?#{query}"
  end

  defp selected_id(%{assigns: assigns}), do: selected_id(assigns)
  defp selected_id(%{selected_resource: nil}), do: nil
  defp selected_id(%{selected_resource: resource}), do: resource.id

  defp selected?(nil, _resource), do: false
  defp selected?(selected_resource, resource), do: selected_resource.id == resource.id

  defp lifecycle_form(nil), do: nil

  defp lifecycle_form(resource) do
    to_form(%{"lifecycle_state" => resource.lifecycle_state}, as: :lifecycle)
  end

  defp reload_workspace_resource(socket, resource_id) do
    selected_resource =
      Inventory.get_operational_resource!(socket.assigns.current_scope, resource_id)

    result = list_resources(socket.assigns.current_scope, socket.assigns.filters)

    socket
    |> assign(:selected_resource, selected_resource)
    |> assign(:lifecycle_form, lifecycle_form(selected_resource))
    |> assign(:resources_empty?, result.entries == [])
    |> assign(:page, result.page)
    |> assign(:has_next_page?, result.has_next?)
    |> assign(:resource_count, result.total)
    |> stream(:resources, result.entries, reset: true)
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp lifecycle_dot("active"), do: "size-1.5 rounded-full bg-emerald-500"
  defp lifecycle_dot("inactive"), do: "size-1.5 rounded-full bg-amber-500"
  defp lifecycle_dot("retired"), do: "size-1.5 rounded-full bg-base-content/25"
  defp lifecycle_dot(_state), do: "size-1.5 rounded-full border border-base-content/35"

  defp condition_dot(conditions), do: condition_status_dot(primary_condition(conditions))

  defp condition_status_dot(%{status: "true"}),
    do: "size-1.5 shrink-0 rounded-full bg-emerald-500"

  defp condition_status_dot(%{status: "false"}), do: "size-1.5 shrink-0 rounded-full bg-amber-500"

  defp condition_status_dot(_condition),
    do: "size-1.5 shrink-0 rounded-full border border-base-content/35"

  defp condition_summary([]), do: "Unknown"

  defp condition_summary(conditions) do
    condition = primary_condition(conditions)
    condition.type
  end

  defp primary_condition(conditions) do
    Enum.find(conditions, &(&1.status == "false")) || List.first(conditions)
  end

  defp find_condition(resource, type), do: Enum.find(resource.conditions, &(&1.type == type))
  defp condition_value(nil), do: "Unknown"
  defp condition_value(%{status: "true"}), do: "Yes"
  defp condition_value(%{status: "false", reason: reason}), do: reason || "No"
  defp condition_value(%{status: status}), do: humanize(status)

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

  defp last_observed_at(resource), do: resource.last_observed_at

  defp host_field(%{host: nil}, _field), do: "Not reported"
  defp host_field(%{host: host}, field), do: Map.get(host, field) || "Not reported"

  defp interface_field(%{interfaces: []}, _field), do: "Not reported"

  defp interface_field(%{interfaces: [interface | _]}, :mac_address),
    do: format_mac(interface.mac_address)

  defp interface_field(%{interfaces: [interface | _]}, field),
    do: Map.get(interface, field) || "Not reported"

  defp primary_address(%{interfaces: interfaces}) do
    interfaces
    |> Enum.flat_map(& &1.addresses)
    |> List.first()
    |> case do
      nil -> "Not reported"
      address -> format_inet(address.address)
    end
  end

  defp format_mac(nil), do: "Not reported"

  defp format_mac(%Postgrex.MACADDR{address: address}) do
    address
    |> Tuple.to_list()
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: nil}),
    do: "#{:inet.ntoa(address)}/#{host_prefix(address)}"

  defp format_inet(%Postgrex.INET{address: address, netmask: mask}),
    do: "#{:inet.ntoa(address)}/#{mask}"

  defp host_prefix(address) when tuple_size(address) == 4, do: 32
  defp host_prefix(address) when tuple_size(address) == 8, do: 128

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp humanize(value), do: String.replace(value, "_", " ")
end
