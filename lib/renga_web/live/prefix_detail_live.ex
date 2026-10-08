defmodule RengaWeb.PrefixDetailLive do
  @moduledoc """
  One prefix (RFD 8, "Prefixes"), shown as its size calls for:

    * a container is a child-space map: each cell is the next planning
      level, an allocated cell opens its child, and the summary counts
      children allocated ("5 of 256 /56s");
    * an IPv4 leaf with at most 1,024 addresses is a per-address map with
      host utilization;
    * any other leaf is an address table with counts, never a percentage.

  IPv6 addresses dim the shared prefix so interface identifiers stand out,
  show how each address was assigned, and hide temporary privacy addresses
  unless `?temporary=show`.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.PrefixComponents

  alias Renga.Inventory.Changes
  alias Renga.IPAM
  alias Renga.IPAM.AddressAssignment
  alias Renga.IPAM.Cidr

  @reload_after_ms 400

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    prefix = IPAM.get_prefix!(scope, id)
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(prefix: prefix, page_title: Cidr.format(prefix.prefix), reload_timer: nil)
     |> load_view()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :show_temporary?, params["temporary"] == "show")}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_view()}
  end

  defp load_view(socket) do
    view = IPAM.prefix_view(socket.assigns.current_scope, socket.assigns.prefix)
    assign(socket, view: view, family: Cidr.family(socket.assigns.prefix.prefix))
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
      <.object_page
        id="prefix-detail"
        title={Cidr.format(@prefix.prefix)}
        subtitle={"#{family_label(@family)} · #{table_label(@prefix.vrf)}"}
      >
        <:breadcrumb>
          <.link navigate={prefixes_path(@family, @prefix.vrf)} class="hover:text-fg">
            Prefixes
          </.link>
          <%= for ancestor <- @view.ancestors do %>
            <span aria-hidden="true">/</span>
            <.link navigate={~p"/network/prefixes/#{ancestor.id}"} class="font-mono hover:text-fg">
              {Cidr.format(ancestor.prefix)}
            </.link>
          <% end %>
        </:breadcrumb>
        <:icon><.icon name="hero-globe-alt" class="size-5" /></:icon>
        <:status>
          <span class="inline-flex items-center gap-1.5 rounded-md border border-edge px-2 py-0.5 text-xs text-fg">
            {String.capitalize(@prefix.status)}
          </span>
        </:status>

        <%= case @view.mode do %>
          <% :container -> %>
            <.space_map prefix={@prefix} space={@view.space} children={@view.node.children} />
          <% :address_map -> %>
            <.address_map prefix={@prefix} map={@view.address_map} />
          <% :address_table -> %>
            <.address_table
              prefix={@prefix}
              family={@family}
              addresses={@view.addresses}
              show_temporary?={@show_temporary?}
            />
        <% end %>

        <:aside>
          <.properties id="prefix-properties" title="Prefix">
            <:item label="Family">{family_label(@family)}</:item>
            <:item label="Routing table">{table_label(@prefix.vrf)}</:item>
            <:item label="Size">
              <.size cidr={@prefix.prefix} /> addresses
            </:item>
            <:item
              label="Description"
              blank={is_nil(@prefix.description)}
              placeholder="None"
            >
              {@prefix.description}
            </:item>
            <:item label="Record">
              <.link
                navigate={~p"/inventory/#{@prefix.resource_id}"}
                class="text-link hover:underline"
              >
                {@prefix.resource.name}
              </.link>
            </:item>
          </.properties>

          <section id="prefix-vlans" class="space-y-2">
            <h2 class="text-xs font-medium text-fg-muted">VLANs</h2>
            <p :if={@view.vlans == []} class="text-sm text-fg-muted">Not linked to a VLAN.</p>
            <ul :if={@view.vlans != []} class="space-y-1.5">
              <li :for={vlan <- @view.vlans}>
                <.link
                  navigate={~p"/network/vlans/#{vlan.id}"}
                  class="text-sm text-link hover:underline"
                >
                  VLAN {vlan.vid} · {vlan.name}
                </.link>
              </li>
            </ul>
            <ul :if={@view.counterparts != []} id="prefix-counterparts" class="space-y-1">
              <li :for={counterpart <- @view.counterparts} class="text-xs text-fg-muted">
                {family_label(Cidr.family(counterpart.prefix))} on the same VLAN:
                <.link
                  navigate={~p"/network/prefixes/#{counterpart.id}"}
                  class="font-mono text-fg hover:underline"
                >
                  {Cidr.format(counterpart.prefix)}
                </.link>
              </li>
            </ul>
            <p
              :if={@view.vlans != [] and @view.counterparts == []}
              id="prefix-single-stack"
              class="rounded-md border border-dashed border-warn-line px-2 py-1 text-xs text-warn-text"
            >
              Single-stack: its VLAN carries no {family_label(other_family(@family))} prefix.
            </p>
          </section>
        </:aside>
      </.object_page>
    </Layouts.app>
    """
  end

  attr :prefix, :any, required: true
  attr :space, :map, required: true
  attr :children, :list, required: true

  defp space_map(assigns) do
    ~H"""
    <section id="prefix-space" class="space-y-4">
      <div>
        <h2 class="text-sm font-semibold text-fg">Child space</h2>
        <p id="prefix-space-summary" class="text-sm text-fg-muted">
          <span class="font-mono text-fg">{delimit(@space.allocated)}</span>
          of {delimit(@space.total)} /{@space.level}s allocated<span :if={
            @space.cell_length != @space.level
          }>; each cell is a /{@space.cell_length}</span>.
        </p>
      </div>

      <div
        id="prefix-space-map"
        class="grid gap-0.5"
        style={"grid-template-columns: repeat(#{columns(length(@space.cells))}, minmax(0, 1fr))"}
      >
        <%= for cell <- @space.cells do %>
          <.link
            :if={cell.child}
            navigate={~p"/network/prefixes/#{cell.child.prefix.id}"}
            data-state={cell.state}
            title={cell_title(cell)}
            class={[
              "relative block aspect-square rounded-[2px] transition-opacity hover:opacity-80",
              "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent",
              cell_class(cell.state)
            ]}
          >
            <span class="sr-only">{cell_title(cell)}</span>
          </.link>
          <span
            :if={!cell.child}
            data-state={cell.state}
            title={cell_title(cell)}
            class={["block aspect-square rounded-[2px]", cell_class(cell.state)]}
          />
        <% end %>
      </div>
      <ul class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-fg-muted">
        <li :for={state <- [:allocated, :partial, :free]} class="flex items-center gap-1.5">
          <span class={["size-3 rounded-[2px]", cell_class(state)]} />
          {state |> Atom.to_string() |> String.capitalize()}
        </li>
      </ul>

      <.table
        id="prefix-children"
        rows={@children}
        row_navigate={&~p"/network/prefixes/#{&1.prefix.id}"}
        class="rounded-lg border border-edge bg-surface"
      >
        <:col :let={child} label="Prefix">
          <span class="font-mono text-sm font-medium">{Cidr.format(child.prefix.prefix)}</span>
        </:col>
        <:col :let={child} label="Description" class="hidden text-fg-muted sm:table-cell">
          {child.prefix.description}
        </:col>
        <:col :let={child} label="Inside" class="text-right font-mono text-xs text-fg-muted">
          {if child.children == [], do: "—", else: length(child.children)}
        </:col>
      </.table>
    </section>
    """
  end

  attr :prefix, :any, required: true
  attr :map, :map, required: true

  defp address_map(assigns) do
    ~H"""
    <section id="prefix-address-map" class="space-y-4">
      <div>
        <h2 class="text-sm font-semibold text-fg">Addresses</h2>
        <p id="prefix-utilization" class="text-sm text-fg-muted">
          <span class="font-mono text-fg">{@map.percent}%</span>
          of hosts used: {@map.used} of {@map.usable}.
        </p>
      </div>

      <div
        id="prefix-address-grid"
        class="grid max-w-3xl gap-0.5"
        style={"grid-template-columns: repeat(#{min(length(@map.cells), 32)}, minmax(0, 1fr))"}
      >
        <span
          :for={cell <- @map.cells}
          id={"address-cell-#{cell.offset}"}
          data-state={cell.state}
          title={address_title(cell)}
          class={["block aspect-square rounded-[2px]", address_class(cell.state)]}
        />
      </div>
      <ul class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-fg-muted">
        <li :for={state <- [:used, :free, :network]} class="flex items-center gap-1.5">
          <span class={["size-3 rounded-[2px]", address_class(state)]} />
          {address_legend(state)}
        </li>
      </ul>

      <.table
        id="prefix-used-addresses"
        rows={Enum.filter(@map.cells, &(&1.state == :used))}
        class="rounded-lg border border-edge bg-surface"
      >
        <:col :let={cell} label="Address">
          <span class="font-mono text-sm">{Cidr.format(cell.address)}</span>
        </:col>
        <:col :let={cell} label="Interface">
          <.address_owner address={cell.record} />
        </:col>
        <:empty>No addresses are observed in this prefix yet.</:empty>
      </.table>
    </section>
    """
  end

  attr :prefix, :any, required: true
  attr :family, :atom, required: true
  attr :addresses, :list, required: true
  attr :show_temporary?, :boolean, required: true

  defp address_table(assigns) do
    {temporary, permanent} = Enum.split_with(assigns.addresses, & &1.temporary?)

    assigns =
      assign(assigns,
        temporary_count: length(temporary),
        shown: if(assigns.show_temporary?, do: assigns.addresses, else: permanent)
      )

    ~H"""
    <section id="prefix-address-table" class="space-y-3">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-fg">Addresses</h2>
          <p id="prefix-address-count" class="text-sm text-fg-muted">
            <span class="font-mono text-fg">{delimit(length(@addresses))}</span>
            {if length(@addresses) == 1, do: "address", else: "addresses"} observed<span :if={
              @temporary_count > 0 and !@show_temporary?
            }>, {@temporary_count} temporary hidden</span>.
          </p>
        </div>
        <.link
          :if={@temporary_count > 0}
          id="prefix-toggle-temporary"
          patch={
            if(@show_temporary?,
              do: ~p"/network/prefixes/#{@prefix.id}",
              else: ~p"/network/prefixes/#{@prefix.id}?temporary=show"
            )
          }
          class="text-xs text-link hover:underline"
        >
          {if @show_temporary?, do: "Hide temporary addresses", else: "Show temporary addresses"}
        </.link>
      </div>

      <.table id="prefix-addresses" rows={@shown} class="rounded-lg border border-edge bg-surface">
        <:col :let={entry} label="Address">
          <span
            id={"address-#{entry.address.id}"}
            data-temporary={to_string(entry.temporary?)}
            class="flex items-center gap-2"
          >
            <.address address={entry.address.address} prefix_length={Cidr.length(@prefix.prefix)} />
            <span
              :if={entry.temporary?}
              class="rounded border border-edge px-1 text-[10px] text-fg-muted"
            >
              temporary
            </span>
          </span>
        </:col>
        <:col :let={entry} label="Assigned" class="text-xs text-fg-muted">
          <span data-method={entry.method}>{AddressAssignment.label(entry.method, @family)}</span>
        </:col>
        <:col :let={entry} label="Interface">
          <.address_owner address={entry.address} />
        </:col>
        <:empty>No addresses are observed in this prefix yet.</:empty>
      </.table>
    </section>
    """
  end

  attr :address, :any, required: true

  defp address_owner(assigns) do
    ~H"""
    <span class="flex min-w-0 items-baseline gap-1.5 py-1.5">
      <span class="font-mono text-sm text-fg">{@address.interface.name}</span>
      <.link
        navigate={~p"/inventory/#{@address.resource_id}"}
        class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
      >
        {@address.interface.resource.name}
      </.link>
    </span>
    """
  end

  defp columns(count) when count <= 16, do: count
  defp columns(count) when count <= 64, do: 16
  defp columns(_count), do: 32

  defp cell_title(%{state: :allocated, child: child}), do: Cidr.format(child.prefix.prefix)

  defp cell_title(%{state: :partial, cidr: cidr, count: count}),
    do: "#{Cidr.format(cidr)}: #{count} #{if count == 1, do: "prefix", else: "prefixes"} inside"

  defp cell_title(%{cidr: cidr}), do: "#{Cidr.format(cidr)}: free"

  defp cell_class(:allocated), do: "bg-accent"
  defp cell_class(:partial), do: "bg-accent/40"
  defp cell_class(:free), do: "bg-sunken ring-1 ring-edge ring-inset"

  defp address_title(%{state: :used, address: address, record: record}),
    do: "#{Cidr.format(address)} · #{record.interface.resource.name} #{record.interface.name}"

  defp address_title(%{state: :network, address: address}),
    do: "#{Cidr.format(address)}: network"

  defp address_title(%{state: :broadcast, address: address}),
    do: "#{Cidr.format(address)}: broadcast"

  defp address_title(%{address: address}), do: "#{Cidr.format(address)}: free"

  defp address_class(:used), do: "bg-accent"
  defp address_class(:free), do: "bg-sunken ring-1 ring-edge ring-inset"
  defp address_class(_reserved), do: "bg-fg-subtle/40"

  defp address_legend(:used), do: "Used"
  defp address_legend(:free), do: "Free"
  defp address_legend(:network), do: "Network and broadcast"

  defp other_family(:ipv4), do: :ipv6
  defp other_family(:ipv6), do: :ipv4

  defp prefixes_path(family, vrf) do
    params = Enum.reject([family: family, vrf: vrf], fn {_key, value} -> is_nil(value) end)
    ~p"/network/prefixes?#{params}"
  end
end
