defmodule RengaWeb.ResourceLive.Show do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog
  alias Renga.Inventory

  @lifecycle_options [
    {"Active — in service", "active"},
    {"Inactive — out of service", "inactive"},
    {"Retired — no longer used", "retired"},
    {"Unknown — not classified", "unknown"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = Inventory.get_operational_resource!(socket.assigns.current_scope, id)

    {:ok,
     assign(socket,
       page_title: resource.display_name || resource.name,
       resource: resource,
       lifecycle_options: @lifecycle_options,
       lifecycle_form: lifecycle_form(resource),
       hardware_assignable?: Catalog.hardware_assignable_resource?(resource),
       can_manage_lifecycle?: Inventory.organization_manager?(socket.assigns.current_scope)
     )}
  end

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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:resources}>
      <article id="resource-detail" class="space-y-6">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <.link
              navigate={~p"/inventory/resources"}
              class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/50 transition hover:text-orange-600"
            >
              <.icon name="hero-arrow-left" class="size-3.5" /> Resources
            </.link>
            <div class="mt-4 flex items-center gap-3">
              <span class="grid size-11 place-items-center rounded-xl bg-orange-500/10 text-orange-600">
                <.icon name="hero-server-stack" class="size-6" />
              </span>
              <div>
                <h1 class="text-3xl font-semibold tracking-tight">
                  {@resource.display_name || @resource.name}
                </h1>
                <p class="mt-1 font-mono text-xs uppercase tracking-wider text-base-content/45">
                  {@resource.kind} · {@resource.id}
                </p>
              </div>
            </div>
          </div>
          <div class="flex max-w-sm flex-col items-start gap-1 sm:items-end">
            <.link
              :if={@hardware_assignable?}
              id="resource-hardware-link"
              navigate={~p"/inventory/resources/#{@resource.id}/hardware"}
              class="mb-2 inline-flex h-10 items-center gap-2 rounded-lg border border-base-content/15 bg-base-100 px-4 text-sm font-semibold transition hover:border-orange-500/40 hover:text-orange-600"
            >
              <.icon name="hero-cpu-chip" class="size-4" /> Hardware inventory
            </.link>
            <.form
              :if={@can_manage_lifecycle?}
              for={@lifecycle_form}
              id="resource-lifecycle-form"
              phx-submit="update_lifecycle"
              class="flex items-end gap-2"
            >
              <.input
                field={@lifecycle_form[:lifecycle_state]}
                type="select"
                label="Inventory lifecycle"
                aria-describedby="resource-lifecycle-help"
                options={@lifecycle_options}
                class="h-10 min-w-36 rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium capitalize outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
              />
              <button
                id="resource-lifecycle-save"
                type="submit"
                phx-disable-with="Saving…"
                class="h-10 self-end rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
              >
                Save
              </button>
            </.form>
            <span
              :if={!@can_manage_lifecycle?}
              class={lifecycle_badge_class(@resource.lifecycle_state)}
            >
              {@resource.lifecycle_state}
            </span>
            <p
              id="resource-lifecycle-help"
              class="text-left text-xs leading-5 text-base-content/45 sm:text-right"
            >
              Classifies this resource for planning and filters. It does not control the device or
              reflect agent connectivity.
            </p>
          </div>
        </header>

        <section id="resource-conditions" class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <.condition_card :for={condition <- @resource.conditions} condition={condition} />
          <p
            :if={@resource.conditions == []}
            class="col-span-full rounded-2xl border border-dashed border-base-content/15 p-6 text-sm text-base-content/45"
          >
            No resource conditions have been reported.
          </p>
        </section>

        <div class="grid gap-6 xl:grid-cols-3">
          <div class="space-y-6 xl:col-span-2">
            <.panel
              id="canonical-projection"
              title="Canonical projection"
              subtitle="Current source-neutral host inventory"
            >
              <dl class="grid gap-x-6 gap-y-5 sm:grid-cols-2 lg:grid-cols-3">
                <.datum label="Hostname" value={host_field(@resource, :hostname)} />
                <.datum label="FQDN" value={host_field(@resource, :fqdn)} />
                <.datum label="Vendor" value={host_field(@resource, :vendor)} />
                <.datum label="Model" value={host_field(@resource, :model)} />
                <.datum label="Asset tag" value={host_field(@resource, :asset_tag)} />
                <.datum label="Generation" value={to_string(@resource.generation)} />
              </dl>
            </.panel>

            <.panel
              id="resource-interfaces"
              title="Interfaces and addresses"
              subtitle="Canonical network inventory"
            >
              <div class="divide-y divide-base-content/10">
                <div :if={@resource.interfaces == []} class="py-5 text-sm text-base-content/45">
                  No interfaces reported.
                </div>
                <div
                  :for={interface <- @resource.interfaces}
                  id={"interface-#{interface.id}"}
                  class="grid gap-4 py-5 first:pt-0 last:pb-0 sm:grid-cols-[1fr_1fr_2fr]"
                >
                  <div>
                    <p class="font-mono text-sm font-semibold">{interface.name}</p>
                    <p class="mt-1 text-xs capitalize text-base-content/45">
                      {interface.kind} · {interface.status}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs uppercase tracking-wider text-base-content/40">MAC</p>
                    <p class="mt-1 font-mono text-xs">{format_mac(interface.mac_address)}</p>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <span
                      :for={address <- interface.addresses}
                      data-address-kind={address.kind}
                      class="rounded-lg bg-base-200 px-2.5 py-1.5 font-mono text-xs"
                    >
                      {format_inet(address.address)}
                    </span>
                    <span :if={interface.addresses == []} class="text-xs text-base-content/35">
                      No addresses
                    </span>
                  </div>
                </div>
              </div>
            </.panel>

            <.panel
              id="identifier-claims"
              title="Identifier claims"
              subtitle="Source assertions retained with provenance"
            >
              <div class="overflow-x-auto">
                <table class="min-w-full text-left text-sm">
                  <thead class="text-xs uppercase tracking-wider text-base-content/40">
                    <tr>
                      <th class="pb-3 font-semibold">Kind</th>
                      <th class="pb-3 font-semibold">Value</th>
                      <th class="pb-3 font-semibold">Source</th>
                      <th class="pb-3 text-right font-semibold">Confidence</th>
                      <th class="pb-3 text-right font-semibold">First seen</th>
                      <th class="pb-3 text-right font-semibold">Last seen</th>
                      <th class="pb-3 text-right font-semibold">Evidence</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-content/10">
                    <tr :if={@resource.identifier_claims == []}>
                      <td colspan="7" class="py-5 text-base-content/45">
                        No source claims retained.
                      </td>
                    </tr>
                    <tr
                      :for={claim <- @resource.identifier_claims}
                      id={"claim-#{claim.id}"}
                      data-claim-kind={claim.kind}
                    >
                      <td class="py-3 capitalize text-base-content/55">{humanize(claim.kind)}</td>
                      <td class="py-3 font-mono text-xs">{claim.value}</td>
                      <td class="py-3">{claim.source.name}</td>
                      <td class="py-3 text-right font-mono text-xs">{claim.confidence}%</td>
                      <td class="py-3 text-right font-mono text-xs text-base-content/50">
                        {format_time(claim.first_seen_at)}
                      </td>
                      <td class="py-3 text-right font-mono text-xs text-base-content/50">
                        {format_time(claim.last_seen_at)}
                      </td>
                      <td class="py-3 text-right font-mono text-xs text-base-content/50">
                        {observation_count_label(claim.observation_count)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.panel>
          </div>

          <aside class="space-y-6">
            <.panel id="desired-state" title="Desired state" subtitle="Operator and controller intent">
              <dl class="space-y-3">
                <div
                  :for={{key, value} <- Enum.sort(@resource.spec)}
                  class="rounded-xl bg-base-200/70 p-3"
                >
                  <dt class="text-xs font-medium text-base-content/45">{key}</dt>
                  <dd class="mt-1 break-words font-mono text-xs">{format_value(value)}</dd>
                </div>
                <p :if={@resource.spec == %{}} class="text-sm text-base-content/45">
                  No desired fields set.
                </p>
              </dl>
            </.panel>

            <.panel
              id="canonical-identifiers"
              title="Canonical identifiers"
              subtitle="Server-owned identity"
            >
              <dl class="space-y-3">
                <div :for={identifier <- @resource.identifiers} id={"identifier-#{identifier.id}"}>
                  <dt class="text-xs capitalize text-base-content/45">{humanize(identifier.kind)}</dt>
                  <dd class="mt-1 break-all font-mono text-xs">{identifier.value}</dd>
                </div>
                <p :if={@resource.identifiers == []} class="text-sm text-base-content/45">
                  No canonical identifiers.
                </p>
              </dl>
            </.panel>

            <.panel
              id="change-events"
              title="Recent changes"
              subtitle="Non-authoritative audit history"
            >
              <ol class="space-y-4">
                <li
                  :for={event <- @resource.change_events}
                  id={"change-event-#{event.id}"}
                  class="relative border-l border-base-content/15 pl-4"
                >
                  <span class="absolute -left-1 top-1 size-2 rounded-full bg-orange-500" />
                  <p class="text-sm font-medium capitalize">{humanize(event.kind)}</p>
                  <p class="mt-1 text-xs text-base-content/45">
                    {event.field || "Resource"} · {format_time(event.occurred_at)}
                  </p>
                  <p :if={event.source} class="mt-1 text-xs text-base-content/45">
                    via {event.source.name}
                  </p>
                </li>
                <p :if={@resource.change_events == []} class="text-sm text-base-content/45">
                  No change events.
                </p>
              </ol>
            </.panel>
          </aside>
        </div>
      </article>
    </Layouts.app>
    """
  end

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

  defp lifecycle_badge_class("active") do
    "rounded-full bg-emerald-500/10 px-3 py-1.5 text-xs font-semibold capitalize text-emerald-700 dark:text-emerald-400"
  end

  defp lifecycle_badge_class("inactive") do
    "rounded-full bg-amber-500/10 px-3 py-1.5 text-xs font-semibold capitalize text-amber-700 dark:text-amber-400"
  end

  defp lifecycle_badge_class("retired") do
    "rounded-full bg-base-content/[0.07] px-3 py-1.5 text-xs font-semibold capitalize text-base-content/55"
  end

  defp lifecycle_badge_class(_state) do
    "rounded-full border border-base-content/15 px-3 py-1.5 text-xs font-semibold capitalize text-base-content/55"
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm">
      <h2 class="font-semibold tracking-tight">{@title}</h2>
      <p class="mt-1 text-xs text-base-content/45">{@subtitle}</p>
      <div class="mt-6">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp datum(assigns) do
    ~H"""
    <div>
      <dt class="text-xs uppercase tracking-wider text-base-content/40">{@label}</dt>
      <dd class="mt-1.5 text-sm font-medium">{@value}</dd>
    </div>
    """
  end

  attr :condition, :map, required: true

  defp condition_card(assigns) do
    ~H"""
    <div
      id={"condition-#{@condition.id}"}
      class="rounded-2xl border border-base-content/10 bg-base-100 p-4 shadow-sm"
    >
      <div class="flex items-center justify-between gap-2">
        <p class="truncate text-xs font-semibold">{@condition.type}</p>
        <span class={[
          "size-2 rounded-full",
          @condition.status == "true" && "bg-emerald-500",
          @condition.status == "false" && "bg-rose-500",
          @condition.status == "unknown" && "bg-base-content/25"
        ]} />
      </div>
      <p class="mt-2 text-xs capitalize text-base-content/50">
        {@condition.status} · {@condition.reason || "No reason"}
      </p>
    </div>
    """
  end

  defp host_field(%{host: nil}, _field), do: "Not reported"
  defp host_field(%{host: host}, field), do: Map.get(host, field) || "Not reported"

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

  defp observation_count_label(1), do: "1 observation"
  defp observation_count_label(count), do: "#{count} observations"

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Renga.JSON.encode!(value)

  defp humanize(value), do: value |> String.replace("_", " ")
end
