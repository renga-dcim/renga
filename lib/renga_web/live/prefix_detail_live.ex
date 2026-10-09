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

  Owners and admins edit and delete the prefix (RFD 4, Phase 1); like the
  rest of the Network area, those controls are hidden on a phone.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.PrefixComponents

  alias Renga.Inventory
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
     |> assign(
       can_manage?: Inventory.organization_manager?(scope),
       tables: IPAM.list_routing_tables(scope),
       reload_timer: nil
     )
     |> assign_prefix(prefix)
     |> load_view()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :show_temporary?, params["temporary"] == "show")}
  end

  @impl true
  def handle_event("adopt", %{"id" => address_id}, socket) do
    socket.assigns.current_scope
    |> IPAM.adopt_address(address_id)
    |> address_result(socket, "Address adopted into managed state")
  rescue
    # The address vanished, or the id was tampered with; show what is there now.
    Ecto.NoResultsError -> {:noreply, load_view(socket)}
  end

  def handle_event("release", %{"id" => managed_id}, socket) do
    socket.assigns.current_scope
    |> IPAM.release_address(managed_id)
    |> address_result(socket, "Address released to observed only")
  rescue
    Ecto.NoResultsError -> {:noreply, load_view(socket)}
  end

  def handle_event("validate_prefix", %{"prefix" => params}, socket) do
    changeset =
      socket.assigns.prefix
      |> IPAM.change_prefix(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :prefix_form, to_form(changeset, id: "prefix-edit-form"))}
  end

  def handle_event("update_prefix", %{"prefix" => params}, socket) do
    %{current_scope: scope, prefix: prefix} = socket.assigns

    case IPAM.update_prefix(scope, prefix, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prefix updated")
         |> close_overlay("prefix-edit-panel")
         |> assign(:tables, IPAM.list_routing_tables(scope))
         |> assign_prefix(updated)
         |> load_view()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage prefixes")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :prefix_form, to_form(changeset, id: "prefix-edit-form"))}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, prefix_gone(socket)}
  end

  def handle_event("delete_prefix", _params, socket) do
    %{current_scope: scope, prefix: prefix} = socket.assigns

    case IPAM.delete_prefix(scope, prefix) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prefix #{Cidr.format(prefix.prefix)} deleted")
         |> push_navigate(to: prefixes_path(socket.assigns.family, prefix.vrf))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage prefixes")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, prefix_gone(socket)}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  # Someone may have edited or deleted the prefix meanwhile, so re-read it.
  # Most changes are collector reports elsewhere; the edit form is only
  # rebuilt when the prefix itself changed, so typing is not interrupted.
  def handle_info(:reload, socket) do
    socket = assign(socket, :reload_timer, nil)
    prefix = IPAM.get_prefix!(socket.assigns.current_scope, socket.assigns.prefix.id)

    socket =
      if prefix.updated_at == socket.assigns.prefix.updated_at,
        do: socket,
        else: assign_prefix(socket, prefix)

    {:noreply, load_view(socket)}
  rescue
    Ecto.NoResultsError -> {:noreply, prefix_gone(socket)}
  end

  defp assign_prefix(socket, prefix) do
    assign(socket,
      prefix: prefix,
      page_title: Cidr.format(prefix.prefix),
      prefix_form: to_form(IPAM.change_prefix(prefix), id: "prefix-edit-form")
    )
  end

  defp prefix_gone(socket) do
    socket
    |> put_flash(:error, "That prefix was deleted")
    |> push_navigate(to: prefixes_path(nil, socket.assigns.prefix.vrf))
  end

  defp address_result({:ok, _managed}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> load_view()}

  defp address_result({:error, :forbidden}, socket, _message),
    do: {:noreply, put_flash(socket, :error, "Only owners and admins manage addresses")}

  defp address_result({:error, %Ecto.Changeset{}}, socket, _message),
    do: {:noreply, socket |> put_flash(:error, "That address is already managed") |> load_view()}

  defp load_view(socket) do
    scope = socket.assigns.current_scope
    view = IPAM.prefix_view(scope, socket.assigns.prefix)

    assign(socket,
      view: view,
      family: Cidr.family(socket.assigns.prefix.prefix),
      coverage:
        view.vlans
        |> Enum.map(&{&1, IPAM.vlan_dual_stack(scope, &1.id)})
        |> Enum.reject(fn {_vlan, coverage} -> is_nil(coverage) end)
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
        <:actions :if={@can_manage?}>
          <div class="hidden gap-1.5 sm:flex">
            <.button id="edit-prefix" size="sm" phx-click={show_overlay("prefix-edit-panel")}>
              Edit
            </.button>
            <.button
              id="delete-prefix"
              size="sm"
              variant="danger"
              phx-click={show_overlay("delete-prefix-dialog")}
            >
              Delete
            </.button>
          </div>
        </:actions>
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
            <.address_map
              prefix={@prefix}
              map={@view.address_map}
              entries={@view.addresses}
              can_manage?={@can_manage?}
            />
          <% :address_table -> %>
            <.address_table
              prefix={@prefix}
              family={@family}
              addresses={@view.addresses}
              show_temporary?={@show_temporary?}
              can_manage?={@can_manage?}
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
              :for={{vlan, coverage} <- @coverage}
              id={"prefix-dual-stack-#{vlan.id}"}
              class="text-xs text-fg-muted"
            >
              Dual stack on VLAN {vlan.vid}:
              <span class="font-mono text-fg">{length(coverage.both)} of {coverage.total}</span>
              devices have both families.
              <.link navigate={~p"/network/vlans/#{vlan.id}"} class="text-link hover:underline">
                See which
              </.link>
            </p>
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

      <.side_panel :if={@can_manage?} id="prefix-edit-panel" title="Edit prefix">
        <.form
          for={@prefix_form}
          id="prefix-edit-form"
          phx-change="validate_prefix"
          phx-submit="update_prefix"
          class="space-y-1"
        >
          <.prefix_fields form={@prefix_form} tables={@tables} />
        </.form>
        <:footer>
          <.button
            id="save-prefix"
            variant="primary"
            form="prefix-edit-form"
            phx-disable-with="Saving…"
          >
            Save prefix
          </.button>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        :if={@can_manage?}
        id="delete-prefix-dialog"
        title={"Delete #{Cidr.format(@prefix.prefix)}?"}
        confirm_label="Delete prefix"
        on_confirm="delete_prefix"
      >
        Its VLAN links go with it. Addresses inside it stay, under the next containing
        prefix or none, and Activity keeps its history.
      </.confirm_dialog>
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
  attr :entries, :list, required: true
  attr :can_manage?, :boolean, required: true

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
        <li :for={state <- [:used, :managed, :free, :network]} class="flex items-center gap-1.5">
          <span class={["size-3 rounded-[2px]", address_class(state)]} />
          {address_legend(state)}
        </li>
      </ul>

      <.address_rows
        prefix={@prefix}
        family={:ipv4}
        entries={@entries}
        can_manage?={@can_manage?}
      />
    </section>
    """
  end

  attr :prefix, :any, required: true
  attr :family, :atom, required: true
  attr :addresses, :list, required: true
  attr :show_temporary?, :boolean, required: true
  attr :can_manage?, :boolean, required: true

  defp address_table(assigns) do
    {temporary, permanent} = Enum.split_with(assigns.addresses, & &1.temporary?)

    assigns =
      assign(assigns,
        temporary_count: length(temporary),
        # Rows are per interface, but utilization counts a host once however
        # many interfaces report it (RFD 4, "Utilization").
        observed_count:
          assigns.addresses
          |> Enum.filter(& &1.address)
          |> Enum.uniq_by(&Cidr.to_integer(&1.inet))
          |> length(),
        shown: if(assigns.show_temporary?, do: assigns.addresses, else: permanent)
      )

    ~H"""
    <section id="prefix-address-table" class="space-y-3">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-fg">Addresses</h2>
          <p id="prefix-address-count" class="text-sm text-fg-muted">
            <span class="font-mono text-fg">{delimit(@observed_count)}</span>
            {if @observed_count == 1, do: "address", else: "addresses"} observed<span :if={
              @temporary_count > 0 and !@show_temporary?
            }>, {@temporary_count} temporary records hidden</span>.
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

      <.address_rows
        prefix={@prefix}
        family={@family}
        entries={@shown}
        can_manage?={@can_manage?}
      />
    </section>
    """
  end

  attr :prefix, :any, required: true
  attr :family, :atom, required: true
  attr :entries, :list, required: true
  attr :can_manage?, :boolean, required: true

  # Observed addresses are normal: their status says so plainly, and an
  # owner or admin adopts one when it needs managed state. A managed address
  # nobody reports any more stays listed rather than disappearing.
  defp address_rows(assigns) do
    ~H"""
    <.table id="prefix-addresses" rows={@entries} class="rounded-lg border border-edge bg-surface">
      <:col :let={entry} label="Address">
        <span
          id={entry_id(entry)}
          data-temporary={to_string(entry.temporary?)}
          class="flex items-center gap-2 py-1.5"
        >
          <.address address={entry.inet} prefix_length={Cidr.length(@prefix.prefix)} />
          <span
            :if={entry.temporary?}
            class="rounded border border-edge px-1 text-[10px] text-fg-muted"
          >
            temporary
          </span>
        </span>
      </:col>
      <:col :let={entry} label="Assigned" class="hidden text-xs text-fg-muted sm:table-cell">
        <span :if={entry.method} data-method={entry.method}>
          {AddressAssignment.label(entry.method, @family)}
        </span>
      </:col>
      <:col :let={entry} label="Interface">
        <.address_owner entry={entry} />
      </:col>
      <:col :let={entry} label="Status" class="text-xs">
        <span data-status={entry_status(entry)} class={status_class(entry_status(entry))}>
          {status_label(entry_status(entry))}
        </span>
      </:col>
      <:col :let={entry} :if={@can_manage?} label="" class="w-0 text-right">
        <.button
          :if={entry.address && !entry.managed}
          id={"#{entry_id(entry)}-adopt"}
          size="sm"
          variant="ghost"
          phx-click="adopt"
          phx-value-id={entry.address.id}
        >
          Adopt
        </.button>
        <.button
          :if={entry.managed}
          id={"#{entry_id(entry)}-release"}
          size="sm"
          variant="ghost"
          phx-click="release"
          phx-value-id={entry.managed.id}
        >
          Release
        </.button>
      </:col>
      <:empty>No addresses are observed or managed in this prefix yet.</:empty>
    </.table>
    """
  end

  attr :entry, :map, required: true

  defp address_owner(assigns) do
    assigns =
      assign(
        assigns,
        :interface,
        (assigns.entry.address && assigns.entry.address.interface) ||
          (assigns.entry.managed && assigns.entry.managed.interface)
      )

    ~H"""
    <span :if={@interface} class="flex min-w-0 items-baseline gap-1.5 py-1.5">
      <span class="font-mono text-sm text-fg">{@interface.name}</span>
      <.link
        navigate={~p"/inventory/#{@interface.resource_id}"}
        class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
      >
        {@interface.resource.name}
      </.link>
    </span>
    <span :if={!@interface} class="text-fg-subtle">—</span>
    """
  end

  defp entry_id(%{address: %{id: id}}), do: "address-#{id}"
  defp entry_id(%{managed: %{id: id}}), do: "managed-#{id}"

  defp entry_status(%{address: nil}), do: :managed_unseen
  defp entry_status(%{managed: nil}), do: :observed
  defp entry_status(_entry), do: :managed

  defp status_label(:observed), do: "Observed"
  defp status_label(:managed), do: "Managed"
  defp status_label(:managed_unseen), do: "Managed, not seen"

  defp status_class(:observed), do: "text-fg-muted"
  defp status_class(:managed), do: "font-medium text-fg"
  defp status_class(:managed_unseen), do: "font-medium text-warn-text"

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

  defp address_title(%{state: :managed, address: address}),
    do: "#{Cidr.format(address)}: managed, not seen"

  defp address_title(%{state: :network, address: address}),
    do: "#{Cidr.format(address)}: network"

  defp address_title(%{state: :broadcast, address: address}),
    do: "#{Cidr.format(address)}: broadcast"

  defp address_title(%{address: address}), do: "#{Cidr.format(address)}: free"

  defp address_class(:used), do: "bg-accent"
  defp address_class(:free), do: "bg-sunken ring-1 ring-edge ring-inset"
  defp address_class(:managed), do: "bg-surface ring-2 ring-warn ring-inset"
  defp address_class(_reserved), do: "bg-fg-subtle/40"

  defp address_legend(:used), do: "Used"
  defp address_legend(:free), do: "Free"
  defp address_legend(:managed), do: "Managed, not seen"
  defp address_legend(:network), do: "Network and broadcast"

  defp other_family(:ipv4), do: :ipv6
  defp other_family(:ipv6), do: :ipv4

  defp prefixes_path(family, vrf) do
    params = Enum.reject([family: family, vrf: vrf], fn {_key, value} -> is_nil(value) end)
    ~p"/network/prefixes?#{params}"
  end
end
