defmodule RengaWeb.ResourceHardwareLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog
  alias Renga.Inventory

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = Inventory.get_operational_resource!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:resource, resource)
     |> load_hardware()}
  end

  @impl true
  def handle_event(
        "assign_hardware_type",
        %{"hardware" => %{"hardware_type_id" => hardware_type_id}},
        socket
      ) do
    cond do
      not socket.assigns.hardware_assignable? ->
        {:noreply, put_flash(socket, :error, assignment_error(:unsupported_resource_kind))}

      Enum.any?(socket.assigns.hardware_type_options, &(elem(&1, 1) == hardware_type_id)) ->
        case Catalog.assign_hardware_type(
               socket.assigns.current_scope,
               socket.assigns.resource.id,
               hardware_type_id
             ) do
          {:ok, _assignment} ->
            {:noreply,
             socket
             |> put_flash(:info, "Hardware type assigned")
             |> load_hardware()}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You are not allowed to manage hardware")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, assignment_error(reason))}
        end

      true ->
        {:noreply, put_flash(socket, :error, "Select a hardware type from this organization")}
    end
  end

  def handle_event("clear_hardware_type", _params, socket) do
    if socket.assigns.hardware_assignable? do
      case Catalog.clear_hardware_assignment(
             socket.assigns.current_scope,
             socket.assigns.resource.id
           ) do
        {:ok, nil} ->
          {:noreply,
           socket
           |> put_flash(:info, "Hardware type assignment cleared")
           |> load_hardware()}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to manage hardware")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, assignment_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, assignment_error(:unsupported_resource_kind))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:resources}>
      <main id="resource-hardware" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <.link
              navigate={~p"/inventory/resources/#{@resource.id}"}
              class="inline-flex items-center gap-1.5 text-xs font-semibold text-base-content/50 transition hover:text-orange-600"
            >
              <.icon name="hero-arrow-left" class="size-3.5" /> Resource
            </.link>
            <p class="mt-5 text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Hardware inventory
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">
              {@resource.display_name || @resource.name}
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Catalog expectations, source-neutral components, modules, and inventory-only parts.
            </p>
          </div>
          <.link
            navigate={~p"/inventory/component-findings"}
            class="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-base-content/15 bg-base-100 px-4 text-sm font-semibold transition hover:border-orange-500/40 hover:text-orange-600 lg:self-auto"
          >
            <.icon name="hero-exclamation-triangle" class="size-4" /> Component findings
          </.link>
        </header>

        <section
          id="hardware-assignment"
          class="grid gap-6 rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm lg:grid-cols-[1fr_1.2fr]"
        >
          <div>
            <p class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
              Assigned catalog definition
            </p>
            <%= if @assignment do %>
              <h2 class="mt-3 text-xl font-semibold">
                {@assignment.hardware_type.model}
              </h2>
              <p class="mt-2 text-sm text-base-content/55">
                Revision {@assignment.catalog_type_revision.revision} · {@assignment.origin} assignment
              </p>
              <.link
                navigate={~p"/dcim/hardware-types/#{@assignment.hardware_type.id}"}
                class="mt-4 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
              >
                Inspect pinned definition <.icon name="hero-arrow-right" class="size-4" />
              </.link>
            <% else %>
              <h2 class="mt-3 text-xl font-semibold">Unclassified hardware</h2>
              <p class="mt-2 text-sm leading-6 text-base-content/55">
                Assign a finalized hardware type to materialize expected components.
              </p>
            <% end %>
          </div>

          <div :if={@can_manage_hardware?} class="rounded-xl bg-base-200/60 p-4">
            <.form
              for={@hardware_form}
              id="hardware-assignment-form"
              phx-submit="assign_hardware_type"
              class="flex flex-col gap-3 sm:flex-row sm:items-end"
            >
              <.input
                field={@hardware_form[:hardware_type_id]}
                type="select"
                label="Hardware type"
                prompt="Select a finalized type"
                options={@hardware_type_options}
                class="h-10 min-w-64 rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
              />
              <button
                id="hardware-assignment-save"
                type="submit"
                phx-disable-with="Assigning…"
                class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600"
              >
                Assign
              </button>
            </.form>
            <button
              :if={@assignment}
              id="hardware-assignment-clear"
              type="button"
              phx-click="clear_hardware_type"
              data-confirm="Clear the pinned hardware type and its expected components?"
              class="mt-3 text-xs font-semibold text-rose-600 transition hover:text-rose-700"
            >
              Clear assignment
            </button>
          </div>
          <div
            :if={@hardware_assignable? and !@can_manage_hardware?}
            id="hardware-read-only"
            class="rounded-xl border border-dashed border-base-content/15 p-4 text-sm leading-6 text-base-content/50"
          >
            Read-only access. Organization members, admins, and owners manage catalog assignments.
          </div>
          <div
            :if={!@hardware_assignable?}
            id="hardware-unsupported"
            class="rounded-xl border border-dashed border-base-content/15 p-4 text-sm leading-6 text-base-content/50"
          >
            This resource kind does not support hardware catalog assignments.
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-2">
          <.inventory_panel
            id="expected-components"
            title="Expected components"
            subtitle="Materialized from the pinned catalog revision and asset exceptions"
          >
            <div id="expected-components-list" phx-update="stream" class="space-y-3">
              <div
                id="expected-components-empty"
                class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/45 only:block"
              >
                No component expectations are materialized.
              </div>
              <article
                :for={{dom_id, component} <- @streams.expected_components}
                id={dom_id}
                class="flex items-start justify-between gap-4 rounded-xl bg-base-200/55 p-4"
              >
                <div>
                  <p class="font-semibold">{component.label || component.name}</p>
                  <p class="mt-1 text-xs text-base-content/45">
                    {component.position || "No position"} · {expectation_status(component)}
                  </p>
                </div>
                <span class="rounded-full bg-base-100 px-2.5 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
                  {humanize(component.kind)}
                </span>
              </article>
            </div>
          </.inventory_panel>

          <.inventory_panel
            id="actual-components"
            title="Observed components"
            subtitle="Canonical CPU, memory, and disk projections with retained evidence"
          >
            <div id="actual-components-list" phx-update="stream" class="space-y-3">
              <div
                id="actual-components-empty"
                class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/45 only:block"
              >
                No canonical CPU, memory, or disk evidence is available. Modules and inventory-only parts are tracked separately below.
              </div>
              <article
                :for={{dom_id, component} <- @streams.actual_components}
                id={dom_id}
                class="grid gap-3 rounded-xl bg-base-200/55 p-4 sm:grid-cols-[1fr_auto]"
              >
                <div>
                  <p class="font-semibold">
                    {component.name || component.model || humanize(component.kind)}
                  </p>
                  <p class="mt-1 font-mono text-xs text-base-content/45">
                    {component.slot || component.path || component.serial_number ||
                      "No stable slot reported"}
                  </p>
                </div>
                <div class="text-left sm:text-right">
                  <span class={component_status_class(component.status)}>{component.status}</span>
                  <p class="mt-2 text-xs text-base-content/45">
                    {length(component.evidence_matches)} evidence links
                  </p>
                </div>
                <ul
                  :if={component.evidence_matches != []}
                  class="flex flex-wrap gap-2 sm:col-span-2"
                >
                  <li
                    :for={evidence_match <- component.evidence_matches}
                    id={"component-evidence-match-#{evidence_match.id}"}
                    class="rounded-lg bg-base-100 px-2.5 py-1.5 text-xs text-base-content/55"
                  >
                    {evidence_match.component_evidence.source.name} · {humanize(
                      evidence_match.match_strategy
                    )} · {format_time(evidence_match.component_evidence.observed_at)}
                  </li>
                </ul>
              </article>
            </div>
          </.inventory_panel>
        </div>

        <.inventory_panel
          id="module-inventory"
          title="Module bays"
          subtitle="Desired module types remain separate from currently observed installations"
        >
          <div id="module-bays-list" phx-update="stream" class="grid gap-4 lg:grid-cols-2">
            <div
              id="module-bays-empty"
              class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/45 only:block lg:col-span-2"
            >
              No module bays are registered for this resource.
            </div>
            <article
              :for={{dom_id, bay_state} <- @streams.module_bays}
              id={dom_id}
              class="rounded-xl border border-base-content/10 p-5"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="font-semibold">{bay_state.bay.label || bay_state.bay.name}</h3>
                  <p class="mt-1 text-xs text-base-content/45">
                    {bay_state.bay.position || "No position"}
                  </p>
                </div>
                <span class={component_status_class(bay_state.bay.status)}>
                  {bay_state.bay.status}
                </span>
              </div>
              <dl class="mt-5 grid gap-4 sm:grid-cols-2">
                <.module_state
                  label="Desired"
                  value={module_type_label(bay_state.desired && bay_state.desired.module_type)}
                />
                <.module_state
                  label="Current"
                  value={current_module_label(bay_state.current)}
                />
              </dl>
              <p class="mt-4 text-xs text-base-content/40">
                {length(bay_state.events)} installation events retained
              </p>
            </article>
          </div>
        </.inventory_panel>

        <.inventory_panel
          id="inventory-items"
          title="Inventory-only parts"
          subtitle="Nested assembly records without implicit topology behavior"
        >
          <div id="inventory-items-list" phx-update="stream" class="divide-y divide-base-content/10">
            <div
              id="inventory-items-empty"
              class="hidden py-6 text-center text-sm text-base-content/45 only:block"
            >
              No inventory-only parts are registered.
            </div>
            <article
              :for={{dom_id, item} <- @streams.inventory_items}
              id={dom_id}
              class="grid gap-3 py-4 first:pt-0 last:pb-0 sm:grid-cols-[1fr_1fr_auto]"
            >
              <div>
                <p class="font-semibold">{item.name}</p>
                <p class="mt-1 text-xs uppercase tracking-wide text-base-content/40">
                  {humanize(item.kind)}
                </p>
              </div>
              <div class="text-xs text-base-content/50">
                <p>Position: {item.position || "Not recorded"}</p>
                <p class="mt-1">Parent: {(item.parent && item.parent.name) || "Resource root"}</p>
              </div>
              <span class={component_status_class(item.status)}>{item.status}</span>
            </article>
          </div>
        </.inventory_panel>
      </main>
    </Layouts.app>
    """
  end

  defp load_hardware(socket) do
    scope = socket.assigns.current_scope
    resource = socket.assigns.resource
    hardware_types = Catalog.list_hardware_types(scope)
    assignment = Catalog.get_hardware_assignment(scope, resource.id)
    hardware_assignable? = Catalog.hardware_assignable_resource?(resource)

    module_bays =
      scope
      |> Catalog.list_module_bays(resource.id)
      |> Enum.map(fn bay ->
        %{
          bay: bay,
          desired: Catalog.get_desired_module_assignment(scope, bay.id),
          current: Catalog.get_current_module_installation(scope, bay.id),
          events: Catalog.list_module_installation_events(scope, bay.id)
        }
      end)

    socket
    |> assign(
      page_title: "#{resource.display_name || resource.name} hardware",
      assignment: assignment,
      hardware_assignable?: hardware_assignable?,
      can_manage_hardware?: hardware_assignable? and Catalog.catalog_author?(scope),
      hardware_type_options: hardware_type_options(hardware_types),
      hardware_form: hardware_form(assignment)
    )
    |> stream(:expected_components, Catalog.list_expected_components(scope, resource.id),
      reset: true,
      dom_id: &"expected-component-#{&1.id}"
    )
    |> stream(:actual_components, Catalog.list_actual_components(scope, resource.id),
      reset: true,
      dom_id: &"actual-component-#{&1.id}"
    )
    |> stream(:module_bays, module_bays,
      reset: true,
      dom_id: &"module-bay-#{&1.bay.id}"
    )
    |> stream(:inventory_items, Catalog.list_inventory_items(scope, resource.id),
      reset: true,
      dom_id: &"inventory-item-#{&1.id}"
    )
  end

  defp hardware_type_options(hardware_types) do
    Enum.map(hardware_types, fn hardware_type ->
      {"#{hardware_type.manufacturer.resource.name} #{hardware_type.model}", hardware_type.id}
    end)
  end

  defp hardware_form(assignment) do
    to_form(
      %{"hardware_type_id" => (assignment && assignment.hardware_type_id) || ""},
      as: :hardware
    )
  end

  defp assignment_error(:hardware_type_has_no_revision),
    do: "The selected hardware type has no finalized revision"

  defp assignment_error(:unsupported_resource_kind),
    do: "This resource kind does not support hardware assignments"

  defp assignment_error(_reason), do: "Hardware assignment could not be updated"

  defp expectation_status(%{suppressed: true}), do: "suppressed for this asset"
  defp expectation_status(%{required: true}), do: "required"
  defp expectation_status(_component), do: "optional"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  defp inventory_panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm">
      <h2 class="text-lg font-semibold tracking-tight">{@title}</h2>
      <p class="mt-1 text-sm text-base-content/50">{@subtitle}</p>
      <div class="mt-6">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp module_state(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/40">{@label}</dt>
      <dd class="mt-1 text-sm">{@value}</dd>
    </div>
    """
  end

  defp module_type_label(nil), do: "Not assigned"
  defp module_type_label(module_type), do: module_type.model

  defp current_module_label(nil), do: "Not installed"

  defp current_module_label(installation) do
    installation.module.serial_number || installation.module_type.model
  end

  defp component_status_class(status) when status in ["present", "active", "installed"] do
    "inline-flex rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-emerald-700 dark:text-emerald-400"
  end

  defp component_status_class(status) when status in ["failed", "missing"] do
    "inline-flex rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-rose-700 dark:text-rose-400"
  end

  defp component_status_class(_status) do
    "inline-flex rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55"
  end

  defp humanize(value), do: value |> String.replace("_", " ")
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
