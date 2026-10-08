defmodule RengaWeb.ResourceLive.Index do
  @moduledoc """
  Inventory (RFD 8: "What exists?"): every resource kind in one shared list.

  All list state (search, filters, grouping, sorting, columns, page) lives in
  the URL through `RengaWeb.InventoryQuery`, so any view can be shared or
  bookmarked. Rows open the resource's object page; there is no second,
  partial view of a resource here. The list re-reads itself when the
  organization's inventory changes, so it has no refresh control.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.SavedViews
  alias Renga.SavedViews.SavedView
  alias RengaWeb.Format
  alias RengaWeb.InventoryQuery

  @column_labels %{
    "kind" => "Kind",
    "hardware" => "Hardware",
    "status" => "Lifecycle · Freshness · Agent · Drift",
    "sources" => "Sources",
    "seen" => "Seen"
  }

  # Collector reports arrive in bursts; wait this long after a change before
  # re-reading so one burst causes one reload.
  @reload_after_ms 400

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Inventory",
       can_manage?: Inventory.organization_manager?(scope),
       kinds: Inventory.list_resource_kinds(scope),
       sources: Inventory.list_sources(scope),
       column_labels: @column_labels,
       reload_timer: nil,
       views: SavedViews.list_views(scope, "inventory"),
       view_form: new_view_form()
     )}
  end

  @impl true
  # The list used to open a side panel with ?selected=; resources now have
  # one page, so old links go there.
  def handle_params(%{"selected" => id}, _uri, socket) when id != "" do
    {:noreply, push_navigate(socket, to: ~p"/inventory/#{id}", replace: true)}
  end

  def handle_params(params, _uri, socket) do
    query = InventoryQuery.parse(params)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:active_view, active_view(socket.assigns.views, query))
     |> load_resources()}
  end

  @impl true
  def handle_event("search", %{"q" => search}, socket) do
    {:noreply, patch(socket, %{socket.assigns.query | search: String.trim(search), page: 1})}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    query = %{
      socket.assigns.query
      | kinds: Enum.filter(List.wrap(filter["kinds"]), &(&1 in socket.assigns.kinds)),
        lifecycle: blank_to_nil(filter["lifecycle"]),
        freshness: blank_to_nil(filter["freshness"]),
        source_id: blank_to_nil(filter["source"]),
        page: 1
    }

    {:noreply, patch(socket, query)}
  end

  def handle_event("display", %{"display" => display}, socket) do
    params =
      socket.assigns.query
      |> InventoryQuery.to_params()
      |> Map.merge(%{
        "group" => display["group"],
        "sort" => if(display["direction"] == "desc", do: "-", else: "") <> display["sort"],
        "cols" =>
          display
          |> Map.get("columns", [])
          |> List.wrap()
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(",")
          |> none_if_blank()
      })

    {:noreply, patch(socket, %{InventoryQuery.parse(params) | page: 1})}
  end

  # Selection lives in the URL (`sel`), like every other piece of list state,
  # so a selection can be shared and survives paging and filtering.
  def handle_event("toggle_selection", %{"id" => id}, socket) do
    query = socket.assigns.query

    selected =
      if id in query.selected, do: List.delete(query.selected, id), else: query.selected ++ [id]

    {:noreply, patch(socket, %{query | selected: selected})}
  end

  def handle_event("toggle_page", _params, socket) do
    %{query: query, page_ids: page_ids} = socket.assigns

    selected =
      if all_selected?(query.selected, page_ids),
        do: query.selected -- page_ids,
        else: Enum.uniq(query.selected ++ page_ids)

    {:noreply, patch(socket, %{query | selected: selected})}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, patch(socket, %{socket.assigns.query | selected: []})}
  end

  def handle_event("bulk_lifecycle", %{"state" => state}, socket)
      when state in ~w(active inactive retired unknown) do
    %{current_scope: scope, query: query} = socket.assigns

    case Inventory.update_resources_lifecycle(scope, query.selected, state) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Set #{count_label(count)} to #{state}")
         |> patch(%{query | selected: []})}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage resource lifecycle")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Resources changed while saving; review them and try again")
         |> load_resources()}
    end
  end

  def handle_event("validate_view", %{"saved_view" => attrs}, socket) do
    form =
      %SavedView{}
      |> SavedViews.change_view(Map.put(attrs, "area", "inventory"))
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :view_form, form)}
  end

  def handle_event("save_view", %{"saved_view" => attrs}, socket) do
    %{current_scope: scope, query: query} = socket.assigns

    attrs =
      attrs
      |> Map.take(["name", "shared", "pinned"])
      |> Map.merge(%{"area" => "inventory", "params" => InventoryQuery.view_params(query)})

    case SavedViews.create_view(scope, attrs) do
      {:ok, view} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved view #{view.name}")
         |> close_overlay("save-view")
         |> assign(view_form: new_view_form())
         |> reload_views()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can share views")}

      {:error, changeset} ->
        {:noreply, assign(socket, :view_form, to_form(changeset))}
    end
  end

  def handle_event(
        "toggle_pin",
        _params,
        %{assigns: %{active_view: %SavedView{} = view}} = socket
      ) do
    case SavedViews.update_view(socket.assigns.current_scope, view, %{pinned: !view.pinned}) do
      {:ok, view} ->
        message = if view.pinned, do: "Pinned to the sidebar", else: "Removed from the sidebar"
        {:noreply, socket |> put_flash(:info, message) |> reload_views()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "You cannot change this view")}
    end
  end

  def handle_event(
        "delete_view",
        _params,
        %{assigns: %{active_view: %SavedView{} = view}} = socket
      ) do
    case SavedViews.delete_view(socket.assigns.current_scope, view) do
      {:ok, view} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted view #{view.name}")
         |> reload_views()
         |> push_patch(to: ~p"/inventory")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "You cannot delete this view")}
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
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(reload_timer: nil, kinds: Inventory.list_resource_kinds(scope))
     |> load_resources()}
  end

  defp patch(socket, query), do: push_patch(socket, to: list_path(query))

  defp reload_views(socket) do
    views = SavedViews.list_views(socket.assigns.current_scope, "inventory")

    socket
    |> assign(views: views, active_view: active_view(views, socket.assigns.query))
    |> RengaWeb.SidebarViews.refresh()
  end

  # The view whose query the list is showing, if any. Page and selection do
  # not count: a view stays active while paging through it.
  defp active_view(views, query) do
    params = InventoryQuery.view_params(query)
    Enum.find(views, &(&1.params == params))
  end

  defp new_view_form, do: %SavedView{} |> SavedViews.change_view() |> to_form()

  defp view_path(%SavedView{params: params}), do: params |> InventoryQuery.parse() |> list_path()

  defp load_resources(socket) do
    scope = socket.assigns.current_scope
    query = socket.assigns.query
    options = InventoryQuery.list_options(query)
    result = Inventory.list_operational_resources(scope, options)

    group_counts =
      if query.group, do: Inventory.count_operational_resources_by(scope, options, query.group)

    socket
    |> assign(
      resource_count: result.total,
      page: result.page,
      has_next_page?: result.has_next?,
      page_ids: Enum.map(result.entries, & &1.id)
    )
    |> stream(:resources, with_group_headers(result.entries, query.group, group_counts),
      reset: true
    )
  end

  # Group headers are stream entries placed before the first row of each
  # group; the shared table renders them as full-width header rows.
  defp with_group_headers(resources, nil, _counts), do: resources

  defp with_group_headers(resources, group, counts) do
    resources
    |> Enum.chunk_by(&group_key(&1, group))
    |> Enum.flat_map(fn [first | _] = rows ->
      key = group_key(first, group)

      header = %{
        id: "group-#{group}-#{key}",
        group: %{label: group_label(group, key), count: Map.get(counts, key, length(rows))}
      }

      [header | rows]
    end)
  end

  defp group_key(resource, :kind), do: resource.kind
  defp group_key(resource, :lifecycle), do: resource.lifecycle_state

  defp group_key(resource, :freshness) do
    case Enum.find(resource.conditions, &(&1.type == "InventoryCurrent")) do
      %{status: "true"} -> "current"
      %{status: "false"} -> "stale"
      _missing -> "unknown"
    end
  end

  defp group_label(:freshness, key), do: freshness_label(key)
  defp group_label(_group, key), do: key |> Format.humanize() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:inventory}
    >
      <section id="resource-list" class={["space-y-4", @query.selected != [] && "pb-20"]}>
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div class="flex items-baseline gap-2.5">
            <h1 class="text-xl font-semibold tracking-tight text-fg">Inventory</h1>
            <span id="resource-count" class="font-mono text-xs tabular-nums text-fg-muted">
              {@resource_count}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.display_menu query={@query} column_labels={@column_labels} />
          </div>
        </header>

        <.view_tabs
          views={@views}
          active_view={@active_view}
          query={@query}
          current_scope={@current_scope}
        />

        <div class="flex flex-wrap items-center gap-2">
          <form id="resource-search" phx-change="search" phx-submit="search" class="w-full sm:w-72">
            <label for="resource-search-input" class="sr-only">Search inventory</label>
            <div class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-fg-subtle"
              />
              <input
                id="resource-search-input"
                name="q"
                type="search"
                value={@query.search}
                placeholder="Search names, hosts, serials"
                autocomplete="off"
                phx-debounce="250"
                class="h-control min-h-tap w-full rounded-md border border-edge bg-surface pl-8 pr-3 text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none focus:ring-2 focus:ring-ring"
              />
            </div>
          </form>

          <.filter_chips query={@query} sources={@sources} />
          <.filter_menu query={@query} kinds={@kinds} sources={@sources} />
        </div>

        <div id="resource-keys" phx-hook="ListKeys" data-filter="#resource-search-input">
          <.table
            id="resources"
            rows={@streams.resources}
            row_item={fn {_id, item} -> item end}
            row_group={fn {_id, item} -> Map.get(item, :group) end}
            row_navigate={fn {_id, resource} -> ~p"/inventory/#{resource}" end}
            row_checked={fn {_id, resource} -> resource.id in @query.selected end}
            row_check_id={fn {_id, resource} -> resource.id end}
            row_check_label={
              fn {_id, resource} -> "Select #{resource.display_name || resource.name}" end
            }
            on_check="toggle_selection"
            on_check_all="toggle_page"
            all_checked={all_selected?(@query.selected, @page_ids)}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={resource} label="Name" class="min-w-56">
              <span class="truncate font-medium text-fg">
                {resource.display_name || resource.name}
              </span>
              <span
                :if={resource.display_name && resource.display_name != resource.name}
                class="ml-2 truncate text-fg-subtle"
              >
                {resource.name}
              </span>
            </:col>
            <:col :let={resource} :if={"kind" in @query.columns} label="Kind" class="text-fg-muted">
              {Format.humanize(resource.kind)}
            </:col>
            <:col
              :let={resource}
              :if={"hardware" in @query.columns}
              label="Hardware"
              class="max-w-56 truncate text-fg-muted"
            >
              {hardware_name(resource)}
            </:col>
            <:col :let={resource} :if={"status" in @query.columns} label={@column_labels["status"]}>
              <.resource_status resource={resource} />
            </:col>
            <:col
              :let={resource}
              :if={"sources" in @query.columns}
              label="Sources"
              class="max-w-48 truncate text-fg-muted"
            >
              {source_names(resource)}
            </:col>
            <:col
              :let={resource}
              :if={"seen" in @query.columns}
              label="Seen"
              class="whitespace-nowrap font-mono text-xs text-fg-muted"
            >
              <time
                :if={resource.last_observed_at}
                datetime={DateTime.to_iso8601(resource.last_observed_at)}
                title={Format.datetime(resource.last_observed_at)}
              >
                {Format.age(resource.last_observed_at)}
              </time>
              <span :if={is_nil(resource.last_observed_at)} class="text-fg-subtle">Never</span>
            </:col>
            <:empty>
              <%= if InventoryQuery.filtered?(@query) do %>
                No resources match these filters.
                <.link patch={~p"/inventory"} class="ml-1 text-link hover:underline">
                  Clear filters
                </.link>
              <% else %>
                Nothing here yet. Resources appear as collectors report them.
              <% end %>
            </:empty>
          </.table>
        </div>

        <p
          id="list-keys-legend"
          class="hidden items-center gap-4 text-xs text-fg-subtle md:flex"
          aria-hidden="true"
        >
          <span><kbd class="font-mono">J</kbd> <kbd class="font-mono">K</kbd> move</span>
          <span><kbd class="font-mono">↵</kbd> open</span>
          <span><kbd class="font-mono">X</kbd> select</span>
          <span><kbd class="font-mono">F</kbd> filter</span>
        </p>

        <nav
          :if={@page > 1 or @has_next_page?}
          id="resources-pagination"
          class="flex items-center justify-between text-sm"
          aria-label="Inventory pages"
        >
          <.link
            :if={@page > 1}
            id="resources-previous"
            patch={list_path(%{@query | page: @page - 1})}
            class="text-link hover:underline"
          >
            Previous
          </.link>
          <span :if={@page == 1} />
          <span class="font-mono text-xs text-fg-muted">Page {@page}</span>
          <.link
            :if={@has_next_page?}
            id="resources-next"
            patch={list_path(%{@query | page: @page + 1})}
            class="text-link hover:underline"
          >
            Next
          </.link>
          <span :if={!@has_next_page?} />
        </nav>

        <.save_view_panel form={@view_form} can_share?={@can_manage?} />

        <.bulk_bar
          :if={@query.selected != []}
          count={length(@query.selected)}
          can_manage?={@can_manage?}
        />
      </section>
    </Layouts.app>
    """
  end

  # "All" plus the organization's and the person's views. A view is active
  # when the list shows exactly its query; otherwise a changed list offers
  # to be saved as a new view.
  attr :views, :list, required: true
  attr :active_view, :any, required: true
  attr :query, :map, required: true
  attr :current_scope, :map, required: true

  defp view_tabs(assigns) do
    custom? = InventoryQuery.view_params(assigns.query) != %{}

    assigns =
      assign(assigns,
        all?: is_nil(assigns.active_view) and not custom?,
        unsaved?: is_nil(assigns.active_view) and custom?,
        manage?:
          assigns.active_view != nil and
            SavedViews.can_manage?(assigns.current_scope, assigns.active_view)
      )

    ~H"""
    <div class="flex items-center gap-2 border-b border-edge">
      <nav id="view-tabs" aria-label="Views" class="-mb-px flex min-w-0 gap-1 overflow-x-auto">
        <.link
          id="view-all"
          patch={~p"/inventory"}
          aria-current={@all? && "page"}
          class={view_tab_class(@all?)}
        >
          All
        </.link>
        <.link
          :for={view <- @views}
          id={"view-#{view.id}"}
          patch={view_path(view)}
          aria-current={@active_view && @active_view.id == view.id && "page"}
          class={view_tab_class(@active_view && @active_view.id == view.id)}
        >
          <.icon
            :if={is_nil(view.user_id)}
            name="hero-rectangle-stack-mini"
            class="size-3.5 text-fg-subtle"
          />
          {view.name}
          <span :if={is_nil(view.user_id)} class="sr-only">(organization view)</span>
        </.link>
      </nav>
      <span class="flex-1" />
      <.button
        :if={@unsaved?}
        id="save-view-button"
        size="sm"
        variant="ghost"
        phx-click={show_overlay("save-view")}
      >
        <.icon name="hero-plus-mini" class="size-4" /> Save view
      </.button>
      <details :if={@manage?} id="view-options" class="relative">
        <summary
          class="grid size-8 min-h-tap min-w-tap cursor-pointer list-none place-items-center rounded-md text-fg-muted hover:bg-sunken hover:text-fg"
          aria-label={"Options for view #{@active_view.name}"}
        >
          <.icon name="hero-ellipsis-horizontal" class="size-5" />
        </summary>
        <div
          phx-click-away={JS.remove_attribute("open", to: "#view-options")}
          class="absolute right-0 z-30 mt-1 w-52 rounded-lg border border-edge bg-surface p-1 shadow-lg"
        >
          <button
            id="view-pin"
            type="button"
            phx-click={JS.remove_attribute("open", to: "#view-options") |> JS.push("toggle_pin")}
            class="flex min-h-tap w-full items-center gap-2 rounded-md px-2.5 py-2 text-left text-sm text-fg hover:bg-sunken"
          >
            <.icon name="hero-bookmark" class="size-4 text-fg-subtle" />
            {if @active_view.pinned, do: "Remove from sidebar", else: "Pin to sidebar"}
          </button>
          <button
            id="view-delete"
            type="button"
            phx-click={
              JS.remove_attribute("open", to: "#view-options") |> show_overlay("delete-view")
            }
            class="flex min-h-tap w-full items-center gap-2 rounded-md px-2.5 py-2 text-left text-sm text-crit hover:bg-crit-fill"
          >
            <.icon name="hero-trash" class="size-4" /> Delete view
          </button>
        </div>
      </details>
      <.confirm_dialog
        :if={@manage?}
        id="delete-view"
        title={"Delete view #{@active_view.name}?"}
        confirm_label="Delete view"
        on_confirm="delete_view"
      >
        {if is_nil(@active_view.user_id),
          do: "It disappears for everyone in the organization. The resources are not affected.",
          else: "Only the saved view is deleted. The resources are not affected."}
      </.confirm_dialog>
    </div>
    """
  end

  defp view_tab_class(active?) do
    [
      "inline-flex min-h-tap shrink-0 items-center gap-1.5 border-b-2 px-3 py-2 text-sm transition-colors",
      active? && "border-accent font-medium text-fg",
      !active? && "border-transparent text-fg-muted hover:text-fg"
    ]
  end

  attr :form, :map, required: true
  attr :can_share?, :boolean, required: true

  defp save_view_panel(assigns) do
    ~H"""
    <.side_panel
      id="save-view"
      title="Save view"
      description="Keeps these filters, grouping, ordering, and columns under a name."
    >
      <.form for={@form} id="save-view-form" phx-change="validate_view" phx-submit="save_view">
        <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />
        <.input
          :if={@can_share?}
          field={@form[:shared]}
          type="checkbox"
          label="Share with everyone in the organization"
        />
        <p :if={!@can_share?} id="save-view-personal" class="mb-3 text-sm text-fg-muted">
          Only you will see this view. Owners and admins can share views with the organization.
        </p>
        <.input field={@form[:pinned]} type="checkbox" label="Show in the sidebar" />
        <div class="mt-4 flex justify-end gap-2">
          <.button type="button" phx-click={hide_overlay("save-view")}>Cancel</.button>
          <.button id="save-view-submit" variant="primary" phx-disable-with="Saving…">
            Save view
          </.button>
        </div>
      </.form>
    </.side_panel>
    """
  end

  @bulk_lifecycles [
    {"active", "Active", "in service"},
    {"inactive", "Inactive", "out of service"},
    {"retired", "Retired", "no longer used"},
    {"unknown", "Unknown", "not classified"}
  ]

  # Floats over the list while rows are selected (RFD 8: bulk actions appear
  # in a floating bar). Each lifecycle choice confirms with the count first.
  attr :count, :integer, required: true
  attr :can_manage?, :boolean, required: true

  defp bulk_bar(assigns) do
    assigns = assign(assigns, lifecycles: @bulk_lifecycles)

    ~H"""
    <div
      id="bulk-bar"
      role="region"
      aria-label="Selected resources"
      class="fixed inset-x-4 bottom-4 z-30 mx-auto flex max-w-xl flex-wrap items-center gap-2 rounded-xl border border-edge bg-surface px-3 py-2 shadow-xl sm:inset-x-0"
    >
      <span id="bulk-count" class="px-1 text-sm font-medium text-fg">
        {count_label(@count)} selected
      </span>
      <span class="flex-1" />
      <%= if @can_manage? do %>
        <details id="bulk-lifecycle-menu" class="relative">
          <summary class="inline-flex h-control min-h-tap cursor-pointer list-none items-center gap-1.5 rounded-md bg-accent px-3 text-sm font-medium text-accent-fg hover:bg-accent-hover">
            Set lifecycle <.icon name="hero-chevron-up-mini" class="size-4" />
          </summary>
          <div
            phx-click-away={JS.remove_attribute("open", to: "#bulk-lifecycle-menu")}
            class="absolute bottom-full right-0 mb-2 w-56 rounded-lg border border-edge bg-surface p-1 shadow-lg"
          >
            <button
              :for={{state, label, meaning} <- @lifecycles}
              id={"bulk-lifecycle-#{state}-option"}
              type="button"
              phx-click={
                JS.remove_attribute("open", to: "#bulk-lifecycle-menu")
                |> show_overlay("bulk-lifecycle-#{state}")
              }
              class="flex min-h-tap w-full items-center justify-between rounded-md px-2.5 py-2 text-left text-sm text-fg hover:bg-sunken"
            >
              {label} <span class="text-xs text-fg-subtle">{meaning}</span>
            </button>
          </div>
        </details>
      <% else %>
        <span
          id="bulk-lifecycle-unavailable"
          class="inline-flex h-control items-center gap-1.5 rounded-md border border-edge px-3 text-sm text-fg-subtle"
          aria-disabled="true"
        >
          Set lifecycle <span class="text-xs">· Requires the owner or admin role</span>
        </span>
      <% end %>
      <.button id="bulk-clear" size="sm" variant="ghost" phx-click="clear_selection">Clear</.button>

      <.confirm_dialog
        :for={{state, label, _meaning} <- @lifecycles}
        :if={@can_manage?}
        id={"bulk-lifecycle-#{state}"}
        title={"Set #{count_label(@count)} to #{label}?"}
        confirm_label={"Set to #{label}"}
        variant="primary"
        on_confirm={JS.push("bulk_lifecycle", value: %{state: state})}
      >
        Lifecycle classifies resources for planning and filters. It does not change the devices
        or what collectors report.
      </.confirm_dialog>
    </div>
    """
  end

  # Active filters as removable chips ("Kind is server, switch"), so the list
  # always says what it is showing.
  attr :query, :map, required: true
  attr :sources, :list, required: true

  defp filter_chips(assigns) do
    ~H"""
    <ul id="resource-filter-chips" class="contents" aria-label="Active filters">
      <.filter_chip
        :if={@query.kinds != []}
        id="chip-kind"
        label="Kind"
        value={Enum.map_join(@query.kinds, ", ", &Format.humanize/1)}
        clear={list_path(%{@query | kinds: [], page: 1})}
      />
      <.filter_chip
        :if={@query.lifecycle}
        id="chip-lifecycle"
        label="Lifecycle"
        value={@query.lifecycle}
        clear={list_path(%{@query | lifecycle: nil, page: 1})}
      />
      <.filter_chip
        :if={@query.freshness}
        id="chip-freshness"
        label="Freshness"
        value={freshness_label(@query.freshness)}
        clear={list_path(%{@query | freshness: nil, page: 1})}
      />
      <.filter_chip
        :if={@query.source_id}
        id="chip-source"
        label="Source"
        value={source_name(@sources, @query.source_id)}
        clear={list_path(%{@query | source_id: nil, page: 1})}
      />
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :clear, :string, required: true

  defp filter_chip(assigns) do
    ~H"""
    <li
      id={@id}
      class="inline-flex h-control min-h-tap items-center gap-1 rounded-md border border-edge bg-surface pl-2.5 text-xs"
    >
      <span class="text-fg-muted">{@label} is</span>
      <span class="font-medium text-fg">{@value}</span>
      <.link
        patch={@clear}
        class="grid h-full min-w-tap place-items-center rounded-r-md px-1.5 text-fg-subtle hover:text-fg"
        aria-label={"Remove #{@label} filter"}
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </.link>
    </li>
    """
  end

  attr :query, :map, required: true
  attr :kinds, :list, required: true
  attr :sources, :list, required: true

  defp filter_menu(assigns) do
    ~H"""
    <details id="filter-menu" class="relative">
      <summary class="inline-flex h-control min-h-tap cursor-pointer list-none items-center gap-1.5 rounded-md border border-dashed border-edge px-2.5 text-xs text-fg-muted transition hover:border-fg-subtle hover:text-fg">
        <.icon name="hero-plus-mini" class="size-4" /> Filter
      </summary>
      <div
        phx-click-away={JS.remove_attribute("open", to: "#filter-menu")}
        class="absolute left-0 z-30 mt-2 w-72 rounded-lg border border-edge bg-surface p-3 shadow-lg"
      >
        <.form for={%{}} as={:filter} id="filter-form" phx-change="filter">
          <fieldset :if={@kinds != []} class="mb-3">
            <legend class="mb-1.5 text-xs font-medium text-fg-muted">Kind</legend>
            <div class="grid grid-cols-2 gap-x-3 gap-y-1">
              <label
                :for={kind <- @kinds}
                class="inline-flex min-h-tap items-center gap-2 text-sm text-fg"
              >
                <input
                  type="checkbox"
                  name="filter[kinds][]"
                  value={kind}
                  checked={kind in @query.kinds}
                  class="size-4 rounded border-edge accent-[var(--rg-accent)]"
                />
                {Format.humanize(kind)}
              </label>
            </div>
          </fieldset>
          <.input
            id="filter-lifecycle"
            name="filter[lifecycle]"
            type="select"
            label="Lifecycle"
            value={@query.lifecycle}
            prompt="Any lifecycle"
            options={Enum.map(InventoryQuery.lifecycles(), &{String.capitalize(&1), &1})}
          />
          <.input
            id="filter-freshness"
            name="filter[freshness]"
            type="select"
            label="Freshness"
            value={@query.freshness}
            prompt="Any freshness"
            options={Enum.map(InventoryQuery.freshness_states(), &{freshness_label(&1), &1})}
          />
          <.input
            :if={@sources != []}
            id="filter-source"
            name="filter[source]"
            type="select"
            label="Source"
            value={@query.source_id}
            prompt="Any source"
            options={Enum.map(@sources, &{&1.name, &1.id})}
          />
        </.form>
      </div>
    </details>
    """
  end

  # Grouping, ordering, and columns decide how the list is shown; filters
  # decide what is in it.
  attr :query, :map, required: true
  attr :column_labels, :map, required: true

  defp display_menu(assigns) do
    {sort, direction} = assigns.query.sort
    assigns = assign(assigns, sort: Atom.to_string(sort), direction: Atom.to_string(direction))

    ~H"""
    <details id="display-menu" class="relative">
      <summary class="inline-flex h-control min-h-tap cursor-pointer list-none items-center gap-1.5 rounded-md border border-edge bg-surface px-2.5 text-xs text-fg transition hover:border-fg-subtle">
        <.icon name="hero-adjustments-horizontal-mini" class="size-4" /> Display
      </summary>
      <div
        phx-click-away={JS.remove_attribute("open", to: "#display-menu")}
        class="absolute right-0 z-30 mt-2 w-72 rounded-lg border border-edge bg-surface p-3 shadow-lg"
      >
        <.form for={%{}} as={:display} id="display-form" phx-change="display">
          <.input
            id="display-group"
            name="display[group]"
            type="select"
            label="Grouping"
            value={@query.group && Atom.to_string(@query.group)}
            options={[
              {"No grouping", ""},
              {"Kind", "kind"},
              {"Lifecycle", "lifecycle"},
              {"Freshness", "freshness"}
            ]}
          />
          <div class="grid grid-cols-[1fr_auto] gap-2">
            <.input
              id="display-sort"
              name="display[sort]"
              type="select"
              label="Ordering"
              value={@sort}
              options={[
                {"Name", "name"},
                {"Kind", "kind"},
                {"Lifecycle", "lifecycle"},
                {"Last seen", "last_seen"}
              ]}
            />
            <.input
              id="display-direction"
              name="display[direction]"
              type="select"
              label="Direction"
              value={@direction}
              options={[{"Ascending", "asc"}, {"Descending", "desc"}]}
            />
          </div>
          <fieldset>
            <legend class="mb-1.5 text-xs font-medium text-fg-muted">Columns</legend>
            <%!-- Keeps the key present when every box is cleared. --%>
            <input type="hidden" name="display[columns][]" value="" />
            <label
              :for={column <- InventoryQuery.columns()}
              class="flex min-h-tap items-center gap-2 text-sm text-fg"
            >
              <input
                type="checkbox"
                name="display[columns][]"
                value={column}
                checked={column in @query.columns}
                class="size-4 rounded border-edge accent-[var(--rg-accent)]"
              />
              {if(column == "status", do: "Status", else: @column_labels[column])}
            </label>
          </fieldset>
        </.form>
      </div>
    </details>
    """
  end

  defp list_path(query) do
    case InventoryQuery.to_params(query) do
      params when params == %{} -> ~p"/inventory"
      params -> ~p"/inventory?#{params}"
    end
  end

  defp freshness_label("current"), do: "Current"
  defp freshness_label("stale"), do: "Stale"
  defp freshness_label("unknown"), do: "Not reported yet"

  defp source_name(sources, id) do
    case Enum.find(sources, &(&1.id == id)) do
      nil -> "Unknown source"
      source -> source.name
    end
  end

  defp hardware_name(%{host: %{vendor: vendor, model: model}}) do
    case [vendor, model] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> "—"
      name -> name
    end
  end

  defp hardware_name(_resource), do: "—"

  defp source_names(%{source_names: []}), do: "—"
  defp source_names(%{source_names: names}), do: Enum.join(names, ", ")

  defp all_selected?(_selected, []), do: false
  defp all_selected?(selected, page_ids), do: Enum.all?(page_ids, &(&1 in selected))

  defp count_label(1), do: "1 resource"
  defp count_label(count), do: "#{count} resources"

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp none_if_blank(""), do: "none"
  defp none_if_blank(value), do: value
end
