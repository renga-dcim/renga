defmodule RengaWeb.PrefixLive do
  @moduledoc """
  The prefix trees (RFD 8, "Prefixes"), with an address-family switch
  (`?family=ipv4|ipv6|both`) and a routing-table switch (`?vrf=`, global
  when absent) that apply to the whole view.

  "Both" shows each family's own tree side by side and never merges them
  into one row, because containment differs between families. A prefix
  linked to a VLAN that also carries the other family links to its
  counterpart, and selecting either (`?selected=`) highlights both; a
  VLAN-linked prefix whose VLAN lacks the other family is marked
  single-stack.

  A routing table's trees are bounded by what an organization plans, and
  the two trees must be laid out together, so rows are plain assigns.

  Owners and admins create prefixes from a side panel (RFD 4, Phase 1).
  As RFD 8 sets for the Network area, the control is hidden on a phone,
  where prefixes are readable but not editable.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.PrefixComponents

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Prefix
  alias Renga.IPAM
  alias Renga.IPAM.Cidr

  @reload_after_ms 400

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Prefixes",
       reload_timer: nil,
       query: nil,
       can_manage?: Inventory.organization_manager?(scope)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tables = IPAM.list_routing_tables(socket.assigns.current_scope)
    current = socket.assigns.query && socket.assigns.query.vrf

    # Family/selection links carry the last rendered name. Follow its identity
    # even if a rename (or reuse of the old name) raced the debounced reload.
    vrf =
      if current && find_table([current], params["vrf"]),
        do: Enum.find(tables, &(&1 && &1.id == current.id)),
        else: find_table(tables, params["vrf"])

    query = %{
      family: family(params["family"]),
      vrf: vrf,
      selected: params["selected"]
    }

    socket =
      socket
      |> assign(tables: tables, query: query)
      |> assign_prefix_form(IPAM.change_prefix(%Prefix{vrf_id: vrf && vrf.id}))
      |> load_rows()

    if current && table_param(vrf) != params["vrf"],
      do: {:noreply, push_patch(socket, to: prefixes_path(query, []))},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("routing_table", %{"table" => %{"vrf" => name}}, socket) do
    tables = IPAM.list_routing_tables(socket.assigns.current_scope)
    query = %{socket.assigns.query | vrf: find_table(tables, name), selected: nil}

    {:noreply, socket |> assign(:query, query) |> push_patch(to: prefixes_path(query, []))}
  end

  def handle_event("validate_prefix", %{"prefix" => params}, socket) do
    changeset =
      %Prefix{}
      |> IPAM.change_prefix(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_prefix_form(socket, changeset)}
  end

  def handle_event("create_prefix", %{"prefix" => params}, socket) do
    case IPAM.create_prefix(socket.assigns.current_scope, params) do
      {:ok, prefix} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prefix #{Cidr.format(prefix.prefix)} created")
         |> close_overlay("prefix-panel")
         |> push_patch(to: created_path(socket.assigns.query, prefix))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage prefixes")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_prefix_form(socket, changeset)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  # VRFs may have been added, renamed, or removed elsewhere. The table in
  # view is followed by id, so a rename keeps it and moves the URL along.
  def handle_info(:reload, socket) do
    %{query: query, current_scope: scope} = socket.assigns
    tables = IPAM.list_routing_tables(scope)
    vrf = query.vrf && Enum.find(tables, &(&1 && &1.id == query.vrf.id))
    socket = assign(socket, reload_timer: nil, tables: tables)

    if table_param(vrf) == table_param(query.vrf) do
      {:noreply, socket |> assign(:query, %{query | vrf: vrf}) |> load_rows()}
    else
      {:noreply, push_patch(socket, to: prefixes_path(query, vrf: vrf, selected: nil))}
    end
  end

  # Show the new prefix: its routing table, and its family unless both are
  # already shown.
  defp created_path(query, prefix) do
    family = Cidr.family(prefix.prefix)

    prefixes_path(query,
      vrf: prefix.vrf,
      family: if(query.family in [:both, family], do: query.family, else: family),
      selected: nil
    )
  end

  defp assign_prefix_form(socket, changeset),
    do: assign(socket, :prefix_form, to_form(changeset, id: "prefix-form"))

  defp load_rows(socket) do
    %{query: query, current_scope: scope} = socket.assigns
    rows = IPAM.list_prefix_rows(scope, query.vrf && query.vrf.id)

    highlighted =
      case Enum.find(rows.ipv4 ++ rows.ipv6, &(&1.node.prefix.id == query.selected)) do
        nil -> MapSet.new()
        row -> MapSet.new([row.node.prefix.id | Enum.map(row.counterparts, & &1.id)])
      end

    assign(socket,
      rows: rows,
      highlighted: highlighted,
      table_form: to_form(%{"vrf" => table_param(query.vrf) || ""}, as: :table)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:prefixes}
    >
      <section id="prefixes" class="mx-auto max-w-6xl space-y-6 px-6 py-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">Prefixes</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Each address family keeps its own tree. Prefixes serving the same VLAN link to each
              other; the VLAN is where both families are shown together.
            </p>
          </div>
          <div class="flex flex-wrap items-end gap-3">
            <div :if={@can_manage?} class="hidden sm:block">
              <.button id="new-prefix" variant="primary" phx-click={show_overlay("prefix-panel")}>
                New prefix
              </.button>
            </div>
            <.segmented id="prefix-family" label="Address family">
              <:option
                :for={{value, label} <- [ipv4: "IPv4", ipv6: "IPv6", both: "Both"]}
                id={"prefix-family-#{value}"}
                patch={prefixes_path(@query, family: value, selected: nil)}
                active={@query.family == value}
              >
                {label}
              </:option>
            </.segmented>
            <.form for={@table_form} id="prefix-table" phx-change="routing_table" class="w-44">
              <.input
                field={@table_form[:vrf]}
                type="select"
                label="Routing table"
                options={Enum.map(@tables, &{table_label(&1), table_param(&1) || ""})}
              />
            </.form>
          </div>
        </header>

        <div class={[
          "grid gap-6",
          @query.family == :both && "lg:grid-cols-2"
        ]}>
          <.tree
            :for={family <- families(@query.family)}
            family={family}
            rows={@rows[family]}
            query={@query}
            highlighted={@highlighted}
          />
        </div>
      </section>

      <.side_panel
        :if={@can_manage?}
        id="prefix-panel"
        title="New prefix"
        description="A prefix contained by another becomes its child. Each routing table holds a CIDR once."
      >
        <.form
          for={@prefix_form}
          id="prefix-form"
          phx-change="validate_prefix"
          phx-submit="create_prefix"
          class="space-y-1"
        >
          <.prefix_fields form={@prefix_form} tables={@tables} />
        </.form>
        <:footer>
          <.button
            id="create-prefix"
            variant="primary"
            form="prefix-form"
            phx-disable-with="Creating…"
          >
            Create prefix
          </.button>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :family, :atom, required: true
  attr :rows, :list, required: true
  attr :query, :map, required: true
  attr :highlighted, :any, required: true

  defp tree(assigns) do
    ~H"""
    <section id={"prefix-tree-#{@family}"} class="min-w-0 space-y-2">
      <h2 class="text-xs font-medium text-fg-muted">
        {family_label(@family)}
        <span class="font-mono tabular-nums">{length(@rows)}</span>
      </h2>
      <p
        :if={@rows == []}
        id={"prefix-tree-#{@family}-empty"}
        class="rounded-lg border border-dashed border-edge px-4 py-8 text-center text-sm text-fg-muted"
      >
        No {family_label(@family)} prefixes in {table_label(@query.vrf)}.
      </p>
      <ul :if={@rows != []} class="divide-y divide-edge rounded-lg border border-edge bg-surface">
        <li
          :for={row <- @rows}
          id={"prefix-row-#{row.node.prefix.id}"}
          data-highlighted={to_string(MapSet.member?(@highlighted, row.node.prefix.id))}
          class={[
            "flex min-h-tap flex-wrap items-center gap-x-3 gap-y-1 py-1.5 pr-3 transition-colors",
            if(MapSet.member?(@highlighted, row.node.prefix.id),
              do: "bg-accent-tint",
              else: "hover:bg-sunken/60"
            )
          ]}
          style={"padding-left: #{0.75 + row.depth * 1.25}rem"}
        >
          <%!-- The address never shrinks: a narrow row wraps its usage and
                VLAN marks below it instead of drawing over it. --%>
          <span class="flex flex-1 items-baseline gap-2">
            <.icon
              :if={row.depth > 0}
              name="hero-arrow-turn-down-right-mini"
              class="size-3.5 shrink-0 self-center text-fg-subtle"
            />
            <.link
              navigate={~p"/network/prefixes/#{row.node.prefix.id}"}
              class="whitespace-nowrap font-mono text-sm font-medium text-fg hover:underline"
            >
              {Cidr.format(row.node.prefix.prefix)}
            </.link>
            <span
              :if={row.node.prefix.description}
              class="hidden min-w-0 truncate text-xs text-fg-muted sm:inline"
            >
              {row.node.prefix.description}
            </span>
          </span>
          <.usage usage={row.usage} id={"prefix-row-#{row.node.prefix.id}-usage"} />
          <span class="flex flex-wrap items-center gap-1">
            <.link
              :for={vlan <- row.vlans}
              navigate={~p"/network/vlans/#{vlan.id}"}
              class="rounded border border-edge px-1.5 font-mono text-[11px] text-fg-muted hover:text-fg"
              title={"VLAN #{vlan.vid} #{vlan.name}"}
            >
              VLAN {vlan.vid}
            </.link>
            <.link
              :for={counterpart <- row.counterparts}
              id={"prefix-row-#{row.node.prefix.id}-pair-#{counterpart.id}"}
              patch={prefixes_path(@query, selected: row.node.prefix.id)}
              title={"Highlight #{Cidr.format(counterpart.prefix)}, which serves the same VLAN"}
              class="inline-flex items-center gap-1 rounded border border-edge bg-sunken px-1.5 font-mono text-[11px] text-fg hover:border-accent"
            >
              <.icon name="hero-arrows-right-left-mini" class="size-3" />
              {Cidr.format(counterpart.prefix)}
            </.link>
            <span
              :if={row.single_stack?}
              id={"prefix-row-#{row.node.prefix.id}-single-stack"}
              title="Its VLAN carries no prefix of the other family"
              class="rounded border border-dashed border-warn-line px-1.5 text-[11px] text-warn-text"
            >
              {family_label(@family)} only
            </span>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp families(:both), do: [:ipv4, :ipv6]
  defp families(family), do: [family]

  defp family("ipv4"), do: :ipv4
  defp family("ipv6"), do: :ipv6
  defp family(_value), do: :both

  # `?vrf=` names a VRF, matched regardless of case; anything else, including
  # a VRF that no longer exists, is the global table.
  defp find_table(_tables, name) when name in [nil, ""], do: nil

  defp find_table(tables, name) do
    key = String.downcase(name)
    Enum.find(tables, &(&1 && String.downcase(&1.name) == key))
  end

  defp table_param(nil), do: nil
  defp table_param(vrf), do: vrf.name

  # Patch paths keep the view's switches; `nil` drops a parameter and the
  # defaults (both families, global table) stay out of the URL.
  defp prefixes_path(query, overrides) do
    query = Map.merge(query, Map.new(overrides))

    params =
      [
        family: query.family != :both && query.family,
        vrf: table_param(query.vrf),
        selected: query.selected
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    ~p"/network/prefixes?#{params}"
  end
end
