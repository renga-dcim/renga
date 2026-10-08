defmodule RengaWeb.ResourceLive.Index do
  @moduledoc """
  Inventory (RFD 8: "What exists?"): every resource kind in one shared list.

  All list state (search, filters, grouping, sorting, columns, page) lives in
  the URL through `RengaWeb.InventoryQuery`, so any view can be shared or
  bookmarked. Rows open the resource's object page; there is no second,
  partial view of a resource here.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents

  alias Renga.Inventory
  alias RengaWeb.Format
  alias RengaWeb.InventoryQuery

  @column_labels %{
    "kind" => "Kind",
    "hardware" => "Hardware",
    "status" => "Lifecycle · Freshness · Agent · Drift",
    "sources" => "Sources",
    "seen" => "Seen"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Inventory",
       kinds: Inventory.list_resource_kinds(scope),
       sources: Inventory.list_sources(scope),
       column_labels: @column_labels
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
    {:noreply, socket |> assign(:query, query) |> load_resources()}
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

  def handle_event("refresh", _params, socket), do: {:noreply, load_resources(socket)}

  defp patch(socket, query), do: push_patch(socket, to: list_path(query))

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
      has_next_page?: result.has_next?
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
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:inventory}>
      <section id="resource-list" class="space-y-4">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div class="flex items-baseline gap-2.5">
            <h1 class="text-xl font-semibold tracking-tight text-fg">Inventory</h1>
            <span id="resource-count" class="font-mono text-xs tabular-nums text-fg-muted">
              {@resource_count}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.display_menu query={@query} column_labels={@column_labels} />
            <.button id="refresh-resources" size="sm" variant="ghost" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.button>
          </div>
        </header>

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

        <.table
          id="resources"
          rows={@streams.resources}
          row_item={fn {_id, item} -> item end}
          row_group={fn {_id, item} -> Map.get(item, :group) end}
          row_navigate={fn {_id, resource} -> ~p"/inventory/#{resource}" end}
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
      </section>
    </Layouts.app>
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

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp none_if_blank(""), do: "none"
  defp none_if_blank(value), do: value
end
