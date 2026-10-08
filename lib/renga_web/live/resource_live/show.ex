defmodule RengaWeb.ResourceLive.Show do
  @moduledoc """
  A resource's object page (RFD 8, "Object pages"): one layout for every
  resource kind, with domains contributing tabs. This LiveView renders the
  Overview, Network, Sources, and Activity tabs; Hardware is its own page in
  the same frame (`RengaWeb.ResourceHardwareLive`).

  The page re-reads the resource when the organization's inventory changes,
  so collector reports and other people's edits appear without a refresh.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents

  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias RengaWeb.Format

  @lifecycle_options [
    {"Active — in service", "active"},
    {"Inactive — out of service", "inactive"},
    {"Retired — no longer used", "retired"},
    {"Unknown — not classified", "unknown"}
  ]

  @reload_after_ms 400

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_operational_resource!(scope, id)
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: resource.display_name || resource.name,
       resource: resource,
       lifecycle_options: @lifecycle_options,
       lifecycle_form: lifecycle_form(resource),
       hardware_assignable?: Catalog.hardware_assignable_resource?(resource),
       can_manage_lifecycle?: Inventory.organization_manager?(scope),
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "update_lifecycle",
        %{"lifecycle" => %{"lifecycle_state" => lifecycle_state}},
        socket
      ) do
    case Inventory.update_resource_lifecycle(
           socket.assigns.current_scope,
           socket.assigns.resource,
           lifecycle_state
         ) do
      {:ok, _resource} ->
        {:noreply,
         socket
         |> put_flash(:info, "Resource lifecycle updated")
         |> reload_resource()}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "Resource changed elsewhere; review the latest lifecycle and retry")
         |> reload_resource()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage resource lifecycle")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Select a valid lifecycle state")}
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
    {:noreply, socket |> assign(:reload_timer, nil) |> reload_resource()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:inventory}
      content_class="p-0"
      commands={commands(assigns)}
      command_context={@resource.display_name || @resource.name}
    >
      <.resource_frame resource={@resource} tab={tab(@live_action)} hardware?={@hardware_assignable?}>
        <%= case @live_action do %>
          <% :show -> %>
            <.overview resource={@resource} hardware?={@hardware_assignable?} />
          <% :network -> %>
            <.network resource={@resource} />
          <% :sources -> %>
            <.sources resource={@resource} />
          <% :activity -> %>
            <.activity events={@resource.change_events} />
        <% end %>
        <:aside>
          <.lifecycle
            resource={@resource}
            form={@lifecycle_form}
            options={@lifecycle_options}
            can_manage?={@can_manage_lifecycle?}
          />
          <.properties id="resource-properties">
            <:item label="Kind">{Format.humanize(@resource.kind)}</:item>
            <:item
              label="Hostname"
              blank={blank_host?(@resource, :hostname)}
              placeholder="Not reported"
            >
              {host_value(@resource, :hostname)}
            </:item>
            <:item label="FQDN" blank={blank_host?(@resource, :fqdn)} placeholder="Not reported">
              {host_value(@resource, :fqdn)}
            </:item>
            <:item label="Vendor" blank={blank_host?(@resource, :vendor)} placeholder="Not reported">
              {host_value(@resource, :vendor)}
            </:item>
            <:item label="Model" blank={blank_host?(@resource, :model)} placeholder="Not reported">
              {host_value(@resource, :model)}
            </:item>
            <:item
              label="Asset tag"
              blank={blank_host?(@resource, :asset_tag)}
              placeholder="Not reported"
            >
              {host_value(@resource, :asset_tag)}
            </:item>
            <:item
              label="Sources"
              blank={@resource.source_names == []}
              placeholder="No source evidence"
            >
              {Enum.join(@resource.source_names, ", ")}
            </:item>
            <:item label="Last seen">{Format.datetime(@resource.last_observed_at)}</:item>
          </.properties>
        </:aside>
      </.resource_frame>
    </Layouts.app>
    """
  end

  attr :resource, :map, required: true
  attr :form, :map, required: true
  attr :options, :list, required: true
  attr :can_manage?, :boolean, required: true

  defp lifecycle(assigns) do
    ~H"""
    <section id="resource-lifecycle" class="space-y-2">
      <h2 class="text-xs font-semibold uppercase tracking-wider text-fg-muted">Lifecycle</h2>
      <.form
        :if={@can_manage?}
        for={@form}
        id="resource-lifecycle-form"
        phx-submit="update_lifecycle"
        class="flex items-start gap-2"
      >
        <div class="min-w-0 flex-1 [&_.field]:!mb-0">
          <.input
            field={@form[:lifecycle_state]}
            type="select"
            aria-label="Lifecycle"
            aria-describedby="resource-lifecycle-help"
            options={@options}
          />
        </div>
        <.button id="resource-lifecycle-save" variant="primary" phx-disable-with="Saving…">
          Save
        </.button>
      </.form>
      <p :if={!@can_manage?} class="text-sm font-medium capitalize text-fg">
        {@resource.lifecycle_state}
      </p>
      <p id="resource-lifecycle-help" class="text-xs leading-5 text-fg-muted">
        Classifies this resource for planning and filters. It does not control the device or
        reflect agent connectivity.
      </p>
    </section>
    """
  end

  attr :resource, :map, required: true
  attr :hardware?, :boolean, required: true

  defp overview(assigns) do
    ~H"""
    <div class="space-y-6">
      <.link
        :if={@resource.drift_count > 0}
        id="resource-drift"
        navigate={~p"/inventory/#{@resource}/hardware"}
        class="flex items-center gap-3 rounded-lg border border-warn-line bg-warn-fill px-4 py-3 text-sm text-warn-text hover:underline"
      >
        <span aria-hidden="true" class="font-mono">≠</span>
        {drift_label(@resource.drift_count)}, see Hardware
      </.link>

      <section id="resource-conditions" aria-labelledby="resource-conditions-title">
        <h2 id="resource-conditions-title" class="mb-2 text-sm font-semibold text-fg">Conditions</h2>
        <ul class="divide-y divide-line rounded-lg border border-edge bg-surface">
          <li
            :for={condition <- @resource.conditions}
            id={"condition-#{condition.id}"}
            class="flex items-center gap-3 px-4 py-2.5 text-sm"
          >
            <span class={["size-2 shrink-0 rounded-full", condition_color(condition.status)]} />
            <span class="font-medium text-fg">{condition.type}</span>
            <span class="text-fg-muted">{condition.status}</span>
            <span :if={condition.reason} class="ml-auto truncate text-xs text-fg-muted">
              {condition.reason}
            </span>
          </li>
          <li :if={@resource.conditions == []} class="px-4 py-3 text-sm text-fg-muted">
            No conditions reported yet.
          </li>
        </ul>
      </section>

      <section id="desired-state" aria-labelledby="desired-state-title">
        <h2 id="desired-state-title" class="mb-2 text-sm font-semibold text-fg">Desired state</h2>
        <dl
          :if={@resource.spec != %{}}
          class="divide-y divide-line rounded-lg border border-edge bg-surface"
        >
          <div
            :for={{key, value} <- Enum.sort(@resource.spec)}
            class="grid grid-cols-3 items-baseline gap-3 px-4 py-2.5"
          >
            <dt class="text-sm text-fg-muted">{key}</dt>
            <dd class="col-span-2 break-words font-mono text-xs text-fg">{format_value(value)}</dd>
          </div>
        </dl>
        <p :if={@resource.spec == %{}} class="text-sm text-fg-muted">
          No desired fields set. Values collectors report are shown as they are.
        </p>
      </section>

      <section id="recent-activity" aria-labelledby="recent-activity-title">
        <div class="mb-2 flex items-baseline justify-between">
          <h2 id="recent-activity-title" class="text-sm font-semibold text-fg">Recent activity</h2>
          <.link
            patch={~p"/inventory/#{@resource}/activity"}
            class="text-xs text-link hover:underline"
          >
            All activity
          </.link>
        </div>
        <.event_list events={Enum.take(@resource.change_events, 5)} />
      </section>
    </div>
    """
  end

  attr :resource, :map, required: true

  defp network(assigns) do
    ~H"""
    <section id="resource-interfaces" class="space-y-3">
      <p :if={@resource.interfaces == []} class="text-sm text-fg-muted">No interfaces reported.</p>
      <div
        :for={interface <- @resource.interfaces}
        id={"interface-#{interface.id}"}
        class="space-y-3 rounded-lg border border-edge bg-surface p-4"
      >
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <p class="font-mono text-sm font-semibold text-fg">{interface.name}</p>
          <p class="text-xs capitalize text-fg-muted">{interface.kind} · {interface.status}</p>
          <p class="font-mono text-xs text-fg-muted">{format_mac(interface.mac_address)}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <span
            :for={address <- interface.addresses}
            data-address-kind={address.kind}
            class="rounded-md bg-sunken px-2 py-1 font-mono text-xs text-fg"
          >
            {format_inet(address.address)}
          </span>
          <span :if={interface.addresses == []} class="text-xs text-fg-muted">No addresses</span>
        </div>
        <div
          id={"interface-#{interface.id}-layer2-links"}
          class="flex flex-wrap items-center gap-x-4 gap-y-1.5 border-t border-line pt-3"
        >
          <span class="text-xs font-medium text-fg-muted">Layer 2</span>
          <.link
            id={"interface-#{interface.id}-memberships"}
            navigate={~p"/network/vlans?#{[interface_id: interface.id]}" <> "#interface-membership"}
            class="inline-flex items-center gap-1 text-xs text-link hover:underline"
          >
            <.icon name="hero-tag" class="size-3.5" /> VLAN memberships
          </.link>
          <.link
            id={"interface-#{interface.id}-relationships"}
            navigate={~p"/network/topology?#{[interface_id: interface.id]}" <> "#logical-relationships"}
            class="inline-flex items-center gap-1 text-xs text-link hover:underline"
          >
            <.icon name="hero-share" class="size-3.5" /> Logical relationships
          </.link>
          <.link
            id={"interface-#{interface.id}-neighbors"}
            navigate={~p"/network/topology?#{[interface_id: interface.id]}" <> "#observed-neighbors"}
            class="inline-flex items-center gap-1 text-xs text-link hover:underline"
          >
            <.icon name="hero-arrows-right-left" class="size-3.5" /> Observed neighbors
          </.link>
          <.link
            id={"interface-#{interface.id}-cables"}
            navigate={~p"/network/cables?#{[interface_id: interface.id]}" <> "#current-cables"}
            class="inline-flex items-center gap-1 text-xs text-link hover:underline"
          >
            <.icon name="hero-link" class="size-3.5" /> Confirmed cables
          </.link>
        </div>
      </div>
    </section>
    """
  end

  attr :resource, :map, required: true

  defp sources(assigns) do
    ~H"""
    <div class="space-y-6">
      <section id="canonical-identifiers" aria-labelledby="canonical-identifiers-title">
        <h2 id="canonical-identifiers-title" class="mb-2 text-sm font-semibold text-fg">
          Identifiers
        </h2>
        <dl class="divide-y divide-line rounded-lg border border-edge bg-surface">
          <div
            :for={identifier <- @resource.identifiers}
            id={"identifier-#{identifier.id}"}
            class="grid grid-cols-3 items-baseline gap-3 px-4 py-2.5"
          >
            <dt class="text-sm capitalize text-fg-muted">{Format.humanize(identifier.kind)}</dt>
            <dd class="col-span-2 break-all font-mono text-xs text-fg">{identifier.value}</dd>
          </div>
          <p :if={@resource.identifiers == []} class="px-4 py-3 text-sm text-fg-muted">
            No identifiers yet.
          </p>
        </dl>
      </section>

      <section id="identifier-claims" aria-labelledby="identifier-claims-title">
        <h2 id="identifier-claims-title" class="mb-1 text-sm font-semibold text-fg">
          What each source reported
        </h2>
        <p class="mb-2 text-xs text-fg-muted">
          Identity claims are kept with their source, so a disagreement can be traced.
        </p>
        <.table id="claims" rows={@resource.identifier_claims} row_id={&"claim-#{&1.id}"}>
          <:col :let={claim} label="Kind" class="capitalize text-fg-muted">
            <span data-claim-kind={claim.kind}>{Format.humanize(claim.kind)}</span>
          </:col>
          <:col :let={claim} label="Value" class="font-mono text-xs">{claim.value}</:col>
          <:col :let={claim} label="Source">{claim.source.name}</:col>
          <:col :let={claim} label="Confidence" class="text-right font-mono text-xs">
            {claim.confidence}%
          </:col>
          <:col
            :let={claim}
            label="First seen"
            class="whitespace-nowrap font-mono text-xs text-fg-muted"
          >
            {Format.datetime(claim.first_seen_at)}
          </:col>
          <:col
            :let={claim}
            label="Last seen"
            class="whitespace-nowrap font-mono text-xs text-fg-muted"
          >
            {Format.datetime(claim.last_seen_at)}
          </:col>
          <:col
            :let={claim}
            label="Evidence"
            class="whitespace-nowrap text-right text-xs text-fg-muted"
          >
            {observation_count_label(claim.observation_count)}
          </:col>
          <:empty>No source has claimed this resource yet.</:empty>
        </.table>
      </section>
    </div>
    """
  end

  attr :events, :list, required: true

  defp activity(assigns) do
    ~H"""
    <section id="change-events">
      <.event_list events={@events} />
      <p :if={length(@events) >= 20} class="mt-3 text-xs text-fg-muted">
        Showing the latest 20 changes. The
        <.link navigate={~p"/activity"} class="text-link hover:underline">Activity</.link>
        area has the full history for the organization.
      </p>
    </section>
    """
  end

  attr :events, :list, required: true

  defp event_list(assigns) do
    ~H"""
    <ol class="space-y-3">
      <li
        :for={event <- @events}
        id={"change-event-#{event.id}"}
        class="relative border-l border-edge pl-4"
      >
        <span class="absolute -left-1 top-1.5 size-2 rounded-full bg-fg-subtle" />
        <p class="text-sm text-fg">
          <span class="font-medium capitalize">{Format.humanize(event.kind)}</span>
          <span :if={event.field} class="text-fg-muted">{Format.humanize(event.field)}</span>
        </p>
        <p class="mt-0.5 text-xs text-fg-muted">
          {Format.datetime(event.occurred_at)}<span :if={event.source}> · via {event.source.name}</span>
        </p>
      </li>
      <li :if={@events == []} class="text-sm text-fg-muted">No changes recorded yet.</li>
    </ol>
    """
  end

  # Command menu actions for this resource. Each one that cannot run says why,
  # using the same checks that gate the page's own controls.
  defp commands(assigns) do
    [
      %{
        id: "change-lifecycle",
        label: "Change lifecycle",
        icon: "hero-arrow-path-rounded-square",
        run: JS.focus(to: "#resource-lifecycle-form select"),
        unavailable:
          if(!assigns.can_manage_lifecycle?,
            do: "Requires the owner or admin role"
          )
      },
      %{
        id: "open-hardware",
        label: "Open hardware",
        icon: "hero-cpu-chip",
        run: JS.navigate(~p"/inventory/#{assigns.resource.id}/hardware"),
        unavailable:
          if(!assigns.hardware_assignable?,
            do:
              "Only physical devices have hardware; this is a #{Format.humanize(assigns.resource.kind)}"
          )
      }
    ]
  end

  defp tab(:show), do: :overview
  defp tab(action), do: action

  defp lifecycle_form(resource) do
    to_form(%{"lifecycle_state" => resource.lifecycle_state}, as: :lifecycle)
  end

  defp reload_resource(socket) do
    resource =
      Inventory.get_operational_resource!(
        socket.assigns.current_scope,
        socket.assigns.resource.id
      )

    socket
    |> assign(:resource, resource)
    |> assign(:lifecycle_form, lifecycle_form(resource))
  end

  defp blank_host?(%{host: nil}, _field), do: true
  defp blank_host?(%{host: host}, field), do: Map.get(host, field) in [nil, ""]

  defp host_value(%{host: nil}, _field), do: nil
  defp host_value(%{host: host}, field), do: Map.get(host, field)

  defp drift_label(1), do: "1 open hardware finding"
  defp drift_label(count), do: "#{count} open hardware findings"

  defp condition_color("true"), do: "bg-ok"
  defp condition_color("false"), do: "bg-warn"
  defp condition_color(_status), do: "border-[1.5px] border-unknown"

  defp format_mac(nil), do: "No MAC"

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

  defp observation_count_label(1), do: "1 observation"
  defp observation_count_label(count), do: "#{count} observations"

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Renga.JSON.encode!(value)
end
