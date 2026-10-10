defmodule RengaWeb.AddressLive do
  @moduledoc """
  Network → Addresses (RFD 4, Phase 3): search managed addresses, reserve
  new ones, and manage their assignments.

  The list searches by address or CIDR (hosts inside it), or by text across
  the DNS name, description, and assigned interfaces and devices, in one
  routing table or all of them (`?q=`, `?vrf=` with a tagged VRF id, name alias, or `global`,
  `?released=true`). Released addresses are history and hidden by default.

  Owners and admins reserve an address in a side panel, edit its intent,
  assign it to interfaces (one, or several for a shared role), remove one
  assignment, and release it. As RFD 8 sets for the Network area, the
  controls are hidden on a phone.

  The list is capped (`IPAM.address_list_limit/0`) and says so, so it is a
  plain assign, refetched whole when the filter or the data changes.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.FindingComponents, only: [finding_list: 1]

  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.IPAM
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.IpAddress

  @reload_after_ms 400
  @expiry_refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Changes.subscribe(scope)
      Process.send_after(self(), :refresh_expiry, @expiry_refresh_ms)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Addresses",
       can_manage?: Inventory.organization_manager?(scope),
       panel: nil,
       editing: nil,
       reload_timer: nil
     )
     |> reset_panel()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    vrfs = IPAM.list_vrfs(socket.assigns.current_scope)

    query = %{
      q: String.trim(params["q"] || ""),
      table: table_filter(vrfs, params["vrf"]),
      released?: params["released"] == "true"
    }

    {:noreply, socket |> assign(vrfs: vrfs, query: query) |> load_addresses()}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query = %{
      q: String.trim(filter["q"] || ""),
      table: table_filter(socket.assigns.vrfs, filter["vrf"]),
      released?: filter["released"] == "true"
    }

    {:noreply, push_patch(socket, to: addresses_path(query))}
  end

  def handle_event("new", _params, socket) do
    {:noreply, socket |> clear_flash() |> reset_panel() |> assign(panel: :new)}
  end

  # Editing starts from the stored address, which is also the stale-edit
  # baseline for its intent fields.
  def handle_event("edit", %{"id" => id}, socket) do
    ip_address = IPAM.get_ip_address!(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> clear_flash()
     |> reset_panel(ip_address)
     |> assign(panel: :edit, editing: ip_address)
     |> load_address_findings()}
  rescue
    Ecto.NoResultsError -> {:noreply, address_gone(socket)}
    Ecto.Query.CastError -> {:noreply, address_gone(socket)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(panel: nil, editing: nil) |> reset_panel()}
  end

  def handle_event("validate", %{"ip_address" => attrs}, socket) do
    form =
      (socket.assigns.editing || new_address())
      |> IPAM.change_ip_address(attrs)
      |> Map.put(:action, :validate)
      |> to_form(id: socket.assigns.form.id)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"ip_address" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    result =
      if editing,
        do: IPAM.update_ip_address(scope, editing, attrs),
        else: IPAM.create_ip_address(scope, attrs)

    case result do
      {:ok, ip_address} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{host(ip_address)} #{if editing, do: "saved", else: "reserved"}")
         |> close_overlay("address-panel")
         |> assign(panel: nil, editing: nil)
         |> reset_panel()
         |> load_addresses()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, id: socket.assigns.form.id))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage addresses")}

      {:error, :stale} ->
        {:noreply,
         assign(
           socket,
           :edit_error,
           "This address changed elsewhere. Close the panel and edit it again to see the current version."
         )}

      {:error, :retired} ->
        {:noreply, address_gone(socket, "That address was released")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, address_gone(socket)}
  end

  def handle_event("search_interfaces", %{"assign" => %{"interface" => text}}, socket) do
    matches = IPAM.assignable_interfaces(socket.assigns.current_scope, text)
    {:noreply, assign(socket, interface_query: text, interface_matches: matches)}
  end

  def handle_event("assign", %{"interface" => interface_id}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    case IPAM.assign_address(scope, editing.id, interface_id) do
      {:ok, assigned} ->
        {:noreply,
         socket
         |> assign(editing: %{editing | assignments: assigned.assignments}, assign_error: nil)
         |> assign(interface_query: "", interface_matches: [])
         |> load_addresses()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :assign_error, first_error(changeset))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage addresses")}

      {:error, :retired} ->
        {:noreply, address_gone(socket, "That address was released")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, assign(socket, :assign_error, "That interface is gone")}
    Ecto.Query.CastError -> {:noreply, assign(socket, :assign_error, "That interface is gone")}
  end

  def handle_event("unassign", %{"id" => assignment_id}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    # The assignment must belong to this server-owned edit session, not
    # merely to some address in the same organization.
    if socket.assigns.panel == :edit && editing &&
         Enum.any?(editing.assignments, &(&1.id == assignment_id)) do
      case IPAM.unassign_address(scope, assignment_id) do
        {:ok, remaining} ->
          {:noreply,
           socket
           |> assign(editing: %{editing | assignments: remaining.assignments}, assign_error: nil)
           |> load_addresses()}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "Only owners and admins manage addresses")}

        {:error, :not_found} ->
          {:noreply, refresh_assignments(socket)}
      end
    else
      {:noreply, assign(socket, :assign_error, "That assignment is not part of this edit")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, refresh_assignments(socket)}
    Ecto.Query.CastError -> {:noreply, refresh_assignments(socket)}
  end

  def handle_event("release", %{"id" => id}, socket) do
    case IPAM.release_address(socket.assigns.current_scope, id) do
      {:ok, released} ->
        {:noreply, socket |> put_flash(:info, "#{host(released)} released") |> load_addresses()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage addresses")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, address_gone(socket)}
    Ecto.Query.CastError -> {:noreply, address_gone(socket)}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  # Only the list refreshes: an open edit keeps its draft and its baseline,
  # so a concurrent change is caught as stale on save.
  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_addresses()}
  end

  def handle_info(:refresh_expiry, socket) do
    Process.send_after(self(), :refresh_expiry, @expiry_refresh_ms)
    {:noreply, load_address_findings(socket)}
  end

  defp address_gone(socket, message \\ "That address is gone") do
    socket
    |> put_flash(:error, message)
    |> close_overlay("address-panel")
    |> assign(panel: nil, editing: nil)
    |> reset_panel()
    |> load_addresses()
  end

  # Another operator changed the assignments; show them as they are now
  # without touching the draft's baseline.
  defp refresh_assignments(socket) do
    current = IPAM.get_ip_address!(socket.assigns.current_scope, socket.assigns.editing.id)

    assign(socket,
      editing: %{socket.assigns.editing | assignments: current.assignments},
      assign_error: "That assignment was already removed"
    )
  end

  # Explicit openings reset input identity; validation and reloads keep it.
  defp reset_panel(socket, ip_address \\ new_address()) do
    assign(socket,
      edit_error: nil,
      assign_error: nil,
      interface_query: "",
      interface_matches: [],
      form:
        to_form(IPAM.change_ip_address(ip_address),
          id: "address-fields-" <> Ecto.UUID.generate()
        )
    )
  end

  defp new_address, do: %IpAddress{allocation_state: "reserved"}

  defp load_addresses(socket) do
    %{current_scope: scope, query: query} = socket.assigns

    filters = %{
      "q" => query.q,
      "vrf" => table_value(query.table),
      "released" => to_string(query.released?)
    }

    addresses = IPAM.list_ip_addresses(scope, filters)

    assign(socket,
      addresses: addresses,
      truncated?: length(addresses) == IPAM.address_list_limit(),
      filter_form:
        to_form(
          %{
            "q" => query.q,
            "vrf" => table_param(query.table),
            "released" => to_string(query.released?)
          },
          as: :filter
        )
    )
    |> load_address_findings()
  end

  # Open address findings about the listed hosts, by namespace and host: the
  # same host in another routing table is another address.
  defp load_address_findings(socket) do
    %{current_scope: scope, addresses: addresses, editing: editing} = socket.assigns
    hosts = finding_hosts(addresses)

    {editing_findings, editing_total} =
      if editing,
        do:
          Findings.list_address_findings(scope, finding_hosts([editing]), vrf_id: editing.vrf_id),
        else: {[], 0}

    assign(socket,
      findings: Findings.count_address_findings(scope, hosts),
      editing_findings: editing_findings,
      editing_finding_total: editing_total
    )
  end

  defp finding_hosts(addresses) do
    for %{resource: %{lifecycle_state: state}} = address <- addresses,
        state != "retired",
        do: %{address.address | netmask: nil}
  end

  defp findings_for(findings, %IpAddress{} = address),
    do: Map.get(findings, {address.vrf_id, host(address)})

  # Selects use stable tagged identities, so a VRF named `global` cannot
  # collide with the Global table. Existing name-based links remain aliases.
  defp table_filter(_vrfs, "global"), do: :global

  defp table_filter(vrfs, "id:" <> id), do: Enum.find(vrfs, :all, &(&1.id == id))

  defp table_filter(vrfs, name) when is_binary(name) and name != "" do
    key = String.downcase(name)
    Enum.find(vrfs, :all, &(String.downcase(&1.name) == key))
  end

  defp table_filter(_vrfs, _name), do: :all

  defp table_value(:all), do: nil
  defp table_value(:global), do: "global"
  defp table_value(vrf), do: vrf.id

  defp table_param(:all), do: nil
  defp table_param(:global), do: "global"
  defp table_param(vrf), do: "id:" <> vrf.id

  defp addresses_path(query) do
    params =
      Enum.reject(
        [q: query.q, vrf: table_param(query.table), released: query.released? && "true"],
        fn {_key, value} -> value in [nil, "", false] end
      )

    ~p"/network/addresses?#{params}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:addresses}
    >
      <section id="addresses" class="mx-auto max-w-6xl space-y-6 px-6 py-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">Addresses</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Managed addresses: reserved or allocated intent, each host once per routing table.
              Adopt an observed address from its prefix, or reserve one here.
            </p>
          </div>
          <div :if={@can_manage?} class="hidden sm:block">
            <.button id="new-address" variant="primary" phx-click="new">
              Reserve address
            </.button>
          </div>
        </header>

        <.form
          for={@filter_form}
          id="address-filter"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-end gap-3"
        >
          <div class="w-full sm:w-72">
            <.input
              field={@filter_form[:q]}
              type="search"
              label="Search"
              placeholder="192.0.2.0/24, web-01, gw.example.net"
              autocomplete="off"
              phx-debounce="300"
            />
          </div>
          <div class="w-44">
            <.input
              field={@filter_form[:vrf]}
              type="select"
              label="Routing table"
              options={[
                {"All tables", ""},
                {"Global", "global"} | Enum.map(@vrfs, &{&1.name, table_param(&1)})
              ]}
            />
          </div>
          <div class="pb-1">
            <.input field={@filter_form[:released]} type="checkbox" label="Show released" />
          </div>
        </.form>

        <.table
          id="address-list"
          rows={@addresses}
          row_id={&"address-#{&1.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={address} label="Address" class="py-2">
            <span class="block font-mono text-sm font-medium wrap-anywhere text-fg">
              {Cidr.format(address.address)}
            </span>
            <span :if={address.dns_name} class="block text-xs wrap-anywhere text-fg-muted">
              {address.dns_name}
            </span>
            <span :if={address.description} class="block text-xs wrap-anywhere text-fg-subtle">
              {address.description}
            </span>
            <.link
              :if={findings_for(@findings, address)}
              id={"address-#{address.id}-findings"}
              navigate={finding_path(findings_for(@findings, address))}
              class="mt-1 inline-flex items-center gap-1 text-xs text-warn-text hover:underline"
            >
              <.icon name="hero-exclamation-triangle-mini" class="size-3.5" />
              {finding_count(findings_for(@findings, address))}
            </.link>
            <%!-- On a phone the state and assignments move under the
                  address, so one column carries the row. --%>
            <span class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 sm:hidden">
              <span class={[
                "inline-flex items-center rounded-md border px-1.5 text-[11px]",
                state_class(address)
              ]}>
                {state_label(address)}
              </span>
              <span
                :for={assignment <- address.assignments}
                class="text-xs text-fg-muted"
              >
                <span class="font-mono text-fg">{assignment.interface.name}</span>
                {assignment.interface.resource.name}
              </span>
            </span>
          </:col>
          <:col :let={address} label="Routing table" class="hidden whitespace-nowrap sm:table-cell">
            <span class="text-sm text-fg">
              {if address.vrf, do: address.vrf.name, else: "Global"}
            </span>
          </:col>
          <:col :let={address} label="State" class="hidden whitespace-nowrap sm:table-cell">
            <span
              id={"address-#{address.id}-state"}
              class={[
                "inline-flex items-center rounded-md border px-2 py-0.5 text-xs",
                state_class(address)
              ]}
            >
              {state_label(address)}
            </span>
          </:col>
          <:col :let={address} label="Role" class="hidden whitespace-nowrap sm:table-cell">
            <span class="block text-sm text-fg">{role_label(address.role)}</span>
            <span class="block text-xs text-fg-muted">{mode_label(address.management_mode)}</span>
          </:col>
          <:col :let={address} label="Assigned to" class="hidden sm:table-cell">
            <span
              :for={assignment <- address.assignments}
              class="flex min-w-0 items-baseline gap-1.5"
            >
              <span class="font-mono text-sm text-fg">{assignment.interface.name}</span>
              <.link
                navigate={~p"/inventory/#{assignment.interface.resource_id}"}
                class="truncate text-xs text-fg-muted hover:text-fg hover:underline"
              >
                {assignment.interface.resource.name}
              </.link>
            </span>
            <span :if={address.assignments == []} class="text-sm text-fg-subtle">—</span>
          </:col>
          <:action :let={address} :if={@can_manage?}>
            <div :if={current?(address)} class="hidden justify-end gap-3 sm:flex">
              <button
                id={"address-#{address.id}-edit"}
                type="button"
                phx-click={JS.push("edit", value: %{id: address.id})}
                class="min-h-tap cursor-pointer text-sm text-link hover:underline"
              >
                Edit
              </button>
              <button
                id={"address-#{address.id}-release"}
                type="button"
                phx-click={show_overlay("release-address-#{address.id}")}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Release
              </button>
            </div>
          </:action>
          <:empty>
            <%= if @query.q != "" do %>
              No managed address matches “{@query.q}”.
            <% else %>
              No managed addresses yet. Adopt one from a prefix, or reserve one.
            <% end %>
          </:empty>
        </.table>

        <p :if={@truncated?} id="address-list-truncated" class="text-sm text-fg-muted">
          Showing the first {length(@addresses)} addresses; narrow the search to see the rest.
        </p>
      </section>

      <.confirm_dialog
        :for={address <- @addresses}
        :if={@can_manage? && current?(address)}
        id={"release-address-#{address.id}"}
        title={"Release #{host(address)}?"}
        confirm_label="Release address"
        on_confirm={JS.push("release", value: %{id: address.id})}
      >
        {release_consequence(address)} It stays in Activity, and adopting or reserving it again
        brings back the same record.
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage? && @panel}
        id="address-panel"
        show
        on_cancel={JS.push("cancel")}
        title={if @editing, do: "Edit #{host(@editing)}", else: "Reserve address"}
        description={
          if @editing,
            do: "The address and routing table are its identity; release it to plan another.",
            else: "Each host is managed once per routing table, whatever its mask."
        }
      >
        <.form
          for={@form}
          id="address-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-1"
        >
          <p :if={@edit_error} id="address-edit-conflict" role="alert" class="mb-4 text-sm text-crit">
            {@edit_error}
          </p>
          <%= if @editing do %>
            <.properties id="address-identity" title="Identity">
              <:item label="Address">
                <span class="font-mono">{Cidr.format(@editing.address)}</span>
              </:item>
              <:item label="Routing table">
                {if @editing.vrf, do: @editing.vrf.name, else: "Global"}
              </:item>
            </.properties>
          <% else %>
            <.input
              field={@form[:address]}
              value={address_text(@form[:address].value)}
              type="text"
              label="Address"
              placeholder="192.0.2.10/24 or 2001:db8::10/64"
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:vrf_id]}
              type="select"
              label="Routing table"
              options={[{"Global", ""} | Enum.map(@vrfs, &{&1.name, &1.id})]}
            />
          <% end %>
          <.input
            field={@form[:allocation_state]}
            type="select"
            label="State"
            options={Enum.map(IpAddress.allocation_states(), &{String.capitalize(&1), &1})}
          />
          <.input
            field={@form[:role]}
            type="select"
            label="Role"
            options={Enum.map(IpAddress.roles(), &{role_label(&1), &1})}
          />
          <.input
            field={@form[:management_mode]}
            type="select"
            label="Management"
            options={[{"Unknown", ""} | Enum.map(IpAddress.management_modes(), &{mode_label(&1), &1})]}
          />
          <.input
            field={@form[:dns_name]}
            type="text"
            label="DNS name (optional)"
            autocomplete="off"
            spellcheck="false"
          />
          <.input field={@form[:description]} type="text" label="Description (optional)" />
        </.form>

        <section
          :if={@editing && @editing_finding_total > 0}
          id="address-findings"
          class="mt-6 space-y-2 border-t border-edge pt-4"
        >
          <h3 class="text-sm font-semibold text-fg">Findings</h3>
          <.finding_list
            id="address-finding-list"
            findings={@editing_findings}
            total={@editing_finding_total}
          />
        </section>

        <section
          :if={@editing}
          id="address-assignments"
          class="mt-6 space-y-3 border-t border-edge pt-4"
        >
          <div>
            <h3 class="text-sm font-semibold text-fg">Assignments</h3>
            <p class="text-xs text-fg-muted">
              <%= if IPAM.shared_role?(@editing.role) do %>
                A {role_label(@editing.role)} can be assigned to several interfaces.
              <% else %>
                One interface; a VIP, anycast, or first-hop redundancy role can be shared.
              <% end %>
            </p>
          </div>

          <ul
            :if={@editing.assignments != []}
            class="divide-y divide-edge rounded-md border border-edge"
          >
            <li
              :for={assignment <- @editing.assignments}
              id={"assignment-#{assignment.id}"}
              class="flex min-h-tap items-center justify-between gap-3 px-3 py-1.5"
            >
              <span class="min-w-0">
                <span class="font-mono text-sm text-fg">{assignment.interface.name}</span>
                <span class="text-xs text-fg-muted">on {assignment.interface.resource.name}</span>
              </span>
              <button
                id={"assignment-#{assignment.id}-remove"}
                type="button"
                phx-click={JS.push("unassign", value: %{id: assignment.id})}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Remove
              </button>
            </li>
          </ul>
          <p :if={@editing.assignments == []} id="address-unassigned" class="text-sm text-fg-muted">
            Not assigned to any interface.
          </p>

          <.form
            for={%{}}
            as={:assign}
            id="assign-form"
            phx-change="search_interfaces"
            phx-submit="search_interfaces"
          >
            <.input
              type="search"
              name="assign[interface]"
              id="assign-interface"
              value={@interface_query}
              label="Assign to an interface"
              placeholder="eth0, web-01"
              autocomplete="off"
              phx-debounce="250"
            />
          </.form>
          <p :if={@assign_error} id="assign-error" role="alert" class="text-sm text-crit">
            {@assign_error}
          </p>
          <ul :if={@interface_matches != []} id="interface-matches" class="space-y-1">
            <li :for={interface <- @interface_matches}>
              <button
                id={"assign-#{interface.id}"}
                type="button"
                phx-click={JS.push("assign", value: %{interface: interface.id})}
                class="flex min-h-tap w-full cursor-pointer items-center justify-between rounded-md border border-edge px-3 py-1.5 text-left transition-colors hover:border-accent hover:bg-sunken"
              >
                <span>
                  <span class="font-mono text-sm text-fg">{interface.name}</span>
                  <span class="text-xs text-fg-muted">on {interface.resource.name}</span>
                </span>
                <span class="text-sm text-link">Assign</span>
              </button>
            </li>
          </ul>
          <p
            :if={@interface_query != "" && @interface_matches == []}
            id="interface-no-matches"
            class="text-sm text-fg-muted"
          >
            No interface matches “{@interface_query}”.
          </p>
        </section>

        <:footer>
          <.button
            id="save-address"
            variant="primary"
            form="address-form"
            phx-disable-with="Saving…"
          >
            {if @editing, do: "Save address", else: "Reserve address"}
          </.button>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp current?(address), do: address.resource.lifecycle_state != "retired"

  defp finding_count(%{count: 1}), do: "1 finding"
  defp finding_count(%{count: count}), do: "#{count} findings"

  # One finding opens in the Inbox; several open the Inbox's address queue.
  defp finding_path(%{count: 1, id: id}), do: ~p"/inbox?#{[finding: "address:#{id}"]}"
  defp finding_path(_findings), do: ~p"/inbox?#{[domain: "address"]}"

  defp host(%IpAddress{address: address}),
    do: Cidr.format(%{address | netmask: Cidr.bits(Cidr.family(address))})

  # A stored address is a Postgrex.INET; a typed one is still text.
  defp address_text(%Postgrex.INET{} = address), do: Cidr.format(address)
  defp address_text(text), do: text

  defp state_label(address) do
    if current?(address), do: String.capitalize(address.allocation_state), else: "Released"
  end

  defp state_class(address) do
    cond do
      !current?(address) -> "border-dashed border-edge text-fg-subtle"
      address.allocation_state == "reserved" -> "border-dashed border-warn-line text-warn-text"
      true -> "border-edge text-fg"
    end
  end

  defp role_label("vip"), do: "VIP"
  defp role_label(role) when role in ~w(vrrp hsrp glbp carp), do: String.upcase(role)
  defp role_label(role), do: String.capitalize(role)

  defp mode_label(nil), do: "Unknown"
  defp mode_label("dhcp"), do: "DHCP"
  defp mode_label("slaac"), do: "SLAAC"
  defp mode_label(mode), do: String.capitalize(mode)

  defp release_consequence(%{assignments: []}), do: "It has no assignments."
  defp release_consequence(%{assignments: [_]}), do: "Its assignment ends."

  defp release_consequence(%{assignments: assignments}),
    do: "All #{length(assignments)} of its assignments end."

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      %{interface_id: [message | _]} -> "That interface #{message}"
      _other -> "The assignment could not be made"
    end
  end
end
