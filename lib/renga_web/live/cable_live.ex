defmodule RengaWeb.CableLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Topology

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Cables",
       can_manage?: Inventory.organization_manager?(scope),
       assert_form: assert_form(),
       plan_form: plan_form()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    interface_id = blank_to_nil(params["interface_id"])
    interface = interface_id && Inventory.get_interface!(scope, interface_id)

    {:noreply,
     socket
     |> assign(
       interface_id: interface_id,
       interface: interface,
       interface_resource: interface && Inventory.get_resource!(scope, interface.resource_id)
     )
     |> load_cables()}
  end

  @impl true
  def handle_event("validate_cable", %{"cable" => params}, socket) do
    {:noreply, assign(socket, :assert_form, to_form(params, as: :cable))}
  end

  def handle_event("validate_cable", %{"plan" => params}, socket) do
    {:noreply, assign(socket, :plan_form, to_form(params, as: :plan))}
  end

  def handle_event("assert_cable", %{"cable" => params}, socket) do
    scope = socket.assigns.current_scope

    case Topology.assert_cable(scope, %{
           interface_a_id: blank_to_nil(params["interface_a_id"]),
           interface_b_id: blank_to_nil(params["interface_b_id"]),
           cable_type: blank_to_nil(params["cable_type"]),
           label: blank_to_nil(params["label"])
         }) do
      {:ok, _assertion} ->
        {:noreply,
         socket
         |> put_flash(:info, "Current cable confirmed")
         |> assign(:assert_form, assert_form())
         |> load_cables()
         |> close_overlay("assert-cable-panel")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("retract_cable", %{"id" => cable_id}, socket) do
    scope = socket.assigns.current_scope
    cable = Topology.get_cable!(scope, cable_id)

    case Topology.retract_cable(scope, %{
           interface_a_id: cable.interface_a_id,
           interface_b_id: cable.interface_b_id
         }) do
      {:ok, _retraction} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cable retracted; the endpoints are released")
         |> load_cables()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("plan_cable", %{"plan" => params}, socket) do
    scope = socket.assigns.current_scope

    case Topology.put_cable_plan(scope, %{
           interface_a_id: blank_to_nil(params["interface_a_id"]),
           interface_b_id: blank_to_nil(params["interface_b_id"]),
           cable_type: blank_to_nil(params["cable_type"]),
           label: blank_to_nil(params["label"])
         }) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cable plan recorded")
         |> assign(:plan_form, plan_form())
         |> load_cables()
         |> close_overlay("plan-cable-panel")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  def handle_event("delete_plan", %{"id" => plan_id}, socket) do
    scope = socket.assigns.current_scope
    plan = Topology.get_cable_plan!(scope, plan_id)

    case Topology.delete_cable_plan(scope, plan) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cable plan removed")
         |> load_cables()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mutation_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:cables}
    >
      <main id="cables" class="mx-auto max-w-6xl space-y-6 px-6 py-6 lg:px-8">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">Cables</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Desired plans, attributed claims, and the reconciled current cable stay separate.
              Neighbor evidence can propose a claim but never creates cabling.
            </p>
          </div>
          <div class="flex flex-wrap items-center justify-end gap-2">
            <div :if={@interface} class="flex flex-wrap items-center gap-2">
              <span class="inline-flex h-control items-center gap-1.5 rounded-md border border-edge bg-surface px-2.5 text-xs text-fg">
                <.icon name="hero-funnel-mini" class="size-3.5 text-fg-subtle" />
                <span class="font-mono font-medium">{@interface.name}</span>
                <span class="text-fg-muted">· {@interface_resource.name}</span>
              </span>
              <.button
                id="cables-clear-interface"
                variant="ghost"
                size="sm"
                navigate={~p"/network/cables"}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" /> Clear interface filter
              </.button>
            </div>
            <.button
              :if={@can_manage?}
              id="new-cable-plan"
              phx-click={show_overlay("plan-cable-panel")}
            >
              Plan cable
            </.button>
            <.button
              :if={@can_manage?}
              id="new-current-cable"
              variant="primary"
              phx-click={show_overlay("assert-cable-panel")}
            >
              Confirm cable
            </.button>
          </div>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Current cables" value={@cable_count} icon="hero-link-mini" />
          <.summary_card label="Planned cables" value={@plan_count} icon="hero-map-mini" />
          <.summary_card
            label="Claims"
            value={@assertion_count}
            icon="hero-document-check-mini"
          />
        </section>

        <section id="current-cables" class="space-y-2">
          <.section_heading
            title="Current cables"
            tag="Confirmed"
            description="Reconciled from confirmed claims. Each endpoint carries at most one current cable."
          />
          <.table
            id="cables-list"
            rows={@streams.cables}
            row_item={fn {_id, cable} -> cable end}
            overflow="clip"
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={cable} label="First endpoint" clip={false}>
              <.endpoint id={"cable-#{cable.id}-first-endpoint"} interface={cable.interface_a} />
            </:col>
            <:col :let={cable} label="Second endpoint" clip={false}>
              <div class="flex min-w-0 items-center gap-1.5">
                <div class="min-w-0 flex-1">
                  <.endpoint
                    id={"cable-#{cable.id}-second-endpoint"}
                    interface={cable.interface_b}
                  />
                </div>
                <.compact_status
                  id={"cable-#{cable.id}-compact-status"}
                  status={cable.status}
                  default="connected"
                />
              </div>
            </:col>
            <:col :let={cable} label="Type" class="w-28 text-fg-muted" hide_below="xl">
              <span data-cable-type={cable.cable_type}>{cable.cable_type || "—"}</span>
            </:col>
            <:col :let={cable} label="Details" class="text-xs text-fg-muted" hide_below="3xl">
              <span :if={cable.color} class="mr-2 inline-flex items-center gap-1.5">
                <span
                  class="inline-block size-3 rounded-full border border-edge"
                  style={"background-color: #{cable.color}"}
                />
                {cable.color}
              </span>
              <span :if={cable.length_value} class="mr-2">
                {format_length(cable.length_value, cable.length_unit)}
              </span>
              <span :if={cable.label}>“{cable.label}”</span>
            </:col>
            <:col
              :let={cable}
              label="Asserted"
              class="w-40 font-mono text-xs text-fg-muted"
              hide_below="4xl"
            >
              {format_time(cable.last_asserted_at)}
            </:col>
            <:col :let={cable} label="Status" class="w-32" hide_below="xl">
              <.state_label status={cable.status} />
            </:col>
            <:action :let={cable} :if={@can_manage?}>
              <.button
                id={"retract-cable-#{cable.id}"}
                type="button"
                size="sm"
                phx-click={show_overlay("retract-cable-#{cable.id}-dialog")}
                aria-label={"Retract cable #{cable.interface_a.name} to #{cable.interface_b.name}"}
              >
                Retract
              </.button>
              <.confirm_dialog
                id={"retract-cable-#{cable.id}-dialog"}
                title="Retract this cable?"
                confirm_label="Retract cable"
                on_confirm={JS.push("retract_cable", value: %{id: cable.id})}
              >
                Its endpoints are released. The attributed claim remains in history.
              </.confirm_dialog>
            </:action>
            <:empty>No current cable is confirmed in this view.</:empty>
          </.table>
        </section>

        <section id="cable-plans" class="space-y-2">
          <.section_heading
            title="Cable plans"
            tag="Desired"
            description="Desired connectivity only. A plan never reserves an endpoint and can disagree with current cabling without replacing it."
          />
          <.table
            id="plans-list"
            rows={@streams.plans}
            row_item={fn {_id, plan} -> plan end}
            overflow="clip"
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={plan} label="First endpoint" clip={false}>
              <.endpoint id={"plan-#{plan.id}-first-endpoint"} interface={plan.interface_a} />
            </:col>
            <:col :let={plan} label="Second endpoint" clip={false}>
              <div class="flex min-w-0 items-center gap-1.5">
                <div class="min-w-0 flex-1">
                  <.endpoint
                    id={"plan-#{plan.id}-second-endpoint"}
                    interface={plan.interface_b}
                  />
                </div>
                <.compact_status
                  id={"plan-#{plan.id}-compact-status"}
                  status={plan.status}
                  default="planned"
                />
              </div>
            </:col>
            <:col :let={plan} label="Type" class="w-28 text-fg-muted" hide_below="xl">
              {plan.cable_type || "—"}
            </:col>
            <:col :let={plan} label="Label" class="text-fg-muted" hide_below="3xl">
              {plan.label || "—"}
            </:col>
            <:col :let={plan} label="Status" class="w-32" hide_below="xl">
              <span data-plan-status={plan.status}>
                <.state_label status={plan.status} />
              </span>
            </:col>
            <:action :let={plan} :if={@can_manage?}>
              <.button
                id={"delete-plan-#{plan.id}"}
                type="button"
                size="sm"
                phx-click={show_overlay("delete-plan-#{plan.id}-dialog")}
                aria-label={"Remove cable plan #{plan.interface_a.name} to #{plan.interface_b.name}"}
              >
                Remove
              </.button>
              <.confirm_dialog
                id={"delete-plan-#{plan.id}-dialog"}
                title="Remove this cable plan?"
                confirm_label="Remove plan"
                on_confirm={JS.push("delete_plan", value: %{id: plan.id})}
              >
                Desired connectivity for these endpoints is removed.
              </.confirm_dialog>
            </:action>
            <:empty>No cable plan recorded in this view.</:empty>
          </.table>
        </section>

        <section id="cable-claims" class="space-y-2">
          <.section_heading
            title="Cable claims"
            tag="History"
            description="Append-only attributed claims, newest first. Proposals from neighbor evidence are listed here but never reconcile into current cabling."
          />
          <.table
            id="claims-list"
            rows={@streams.assertions}
            row_item={fn {_id, assertion} -> assertion end}
            overflow="clip"
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={assertion} label="Claim" class="w-48">
              <span
                data-claim-kind={assertion.kind}
                data-claim-action={assertion.action}
                class="inline-flex items-center gap-1.5"
              >
                <span class={claim_mark(assertion)} aria-hidden="true" />
                {claim_label(assertion)}
              </span>
            </:col>
            <:col :let={assertion} label="Endpoints" class="font-mono text-fg-muted">
              {endpoint_names(assertion)}
            </:col>
            <:col
              :let={assertion}
              label="Asserted"
              class="w-40 font-mono text-xs text-fg-muted"
              hide_below="xl"
            >
              {format_time(assertion.asserted_at)}
            </:col>
            <:empty>No cable claim recorded in this view.</:empty>
          </.table>
        </section>

        <.action_form
          :if={@can_manage?}
          id="assert-cable-form"
          panel_id="assert-cable-panel"
          title="Confirm current cable"
          subtitle="Records an operator assertion that becomes authoritative cabling for these endpoints."
          button_id="assert-cable"
          button_label="Confirm cable"
          form={@assert_form}
          event="assert_cable"
          interface_options={@interface_options}
        />
        <.action_form
          :if={@can_manage?}
          id="plan-cable-form"
          panel_id="plan-cable-panel"
          title="Plan desired cable"
          subtitle="Records desired connectivity without reserving endpoints or replacing current cabling."
          button_id="plan-cable"
          button_label="Save plan"
          form={@plan_form}
          event="plan_cable"
          interface_options={@interface_options}
        />
      </main>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :tag, :string, required: true
  attr :description, :string, required: true

  defp section_heading(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <h2 class="text-sm font-semibold text-fg">{@title}</h2>
        <p class="mt-0.5 max-w-3xl text-xs text-fg-muted">{@description}</p>
      </div>
      <span class="shrink-0 rounded-sm border border-edge bg-sunken px-1.5 text-[11px] font-medium text-fg-muted">
        {@tag}
      </span>
    </div>
    """
  end

  # Status pairs a color with a shape (docs/design-system.md, "Status"): a
  # filled dot for a connected cable, a ring for planned or anything else.
  attr :status, :string, required: true

  defp state_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 capitalize text-fg">
      <span class={state_mark(@status)} aria-hidden="true" />
      {@status}
    </span>
    """
  end

  defp state_mark("connected"), do: "size-2 shrink-0 rounded-full bg-ok"
  defp state_mark("planned"), do: "size-2 shrink-0 rounded-full border-[1.5px] border-info"
  defp state_mark(_status), do: "size-2 shrink-0 rounded-full border-[1.5px] border-unknown"

  attr :id, :string, required: true
  attr :status, :string, required: true
  attr :default, :string, required: true

  # Narrow tables omit the dedicated status column. Preserve exceptional
  # lifecycle state as a compact overflow control instead of making it look
  # like the section's default state.
  defp compact_status(assigns) do
    ~H"""
    <span
      :if={@status != @default}
      id={@id}
      data-clip
      data-clip-focus
      tabindex="-1"
      aria-label={"Status: #{@status}"}
      class="flex size-5 min-h-tap min-w-tap shrink-0 items-center overflow-hidden whitespace-nowrap rounded-sm text-xs capitalize text-fg focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring @xl:hidden"
    >
      <span class={state_mark(@status)} aria-hidden="true" />
      <span class="ml-1">{@status}</span>
    </span>
    """
  end

  defp load_cables(socket) do
    scope = socket.assigns.current_scope

    opts =
      if socket.assigns.interface_id,
        do: [interface_id: socket.assigns.interface_id],
        else: []

    cables = Topology.list_cables(scope, opts)
    plans = Topology.list_cable_plans(scope, opts)
    assertions = Topology.list_cable_assertions(scope, opts)

    socket
    |> assign(:cable_count, length(cables))
    |> assign(:plan_count, length(plans))
    |> assign(:assertion_count, length(assertions))
    |> assign(:interface_options, interface_options(scope))
    |> stream(:cables, cables, dom_id: &"cable-#{&1.id}", reset: true)
    |> stream(:plans, plans, dom_id: &"plan-#{&1.id}", reset: true)
    |> stream(:assertions, assertions, dom_id: &"claim-#{&1.id}", reset: true)
  end

  defp interface_options(scope) do
    [{"Select a physical interface…", ""}] ++
      Enum.map(
        Inventory.list_organization_interfaces(scope, kind: "ethernet"),
        &{"#{&1.resource.name} / #{&1.name}", &1.id}
      )
  end

  defp endpoint_names(assertion) do
    "#{assertion.interface_a.name} ↔ #{assertion.interface_b.name}"
  end

  defp claim_label(%{kind: "operator", action: "retract"}), do: "Operator retraction"
  defp claim_label(%{kind: "operator"}), do: "Operator assertion"
  defp claim_label(%{kind: "import"}), do: "Imported claim"
  defp claim_label(%{kind: "neighbor_evidence"}), do: "Neighbor proposal"
  defp claim_label(_assertion), do: "Cable claim"

  # A neighbor proposal is unconfirmed evidence that needs an operator's
  # attention; a retraction ends a cable; everything else is a confirmed claim.
  defp claim_mark(%{kind: "neighbor_evidence"}),
    do: "size-2 shrink-0 rounded-full border-[1.5px] border-warn"

  defp claim_mark(%{action: "retract"}),
    do: "size-2 shrink-0 rounded-full border-[1.5px] border-unknown"

  defp claim_mark(_assertion), do: "size-2 shrink-0 rounded-full bg-ok"

  attr :id, :string, required: true
  attr :interface, :any, required: true

  # The interface name is the primary value and the device a secondary one,
  # so the device is cut first when the cell is narrow.
  defp endpoint(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={~p"/inventory/#{@interface.resource_id}"}
      data-clip
      data-clip-focus
      class="block min-h-tap min-w-0 max-w-full content-center truncate rounded-sm font-mono font-medium text-fg transition-colors hover:text-fg focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
    >
      {@interface.name}<span class="font-sans text-xs font-normal text-fg-muted">{" · "}{@interface.resource.name}</span>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :panel_id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :button_id, :string, required: true
  attr :button_label, :string, required: true
  attr :form, :any, required: true
  attr :event, :string, required: true
  attr :interface_options, :list, required: true

  defp action_form(assigns) do
    ~H"""
    <.side_panel
      id={@panel_id}
      title={@title}
      description={@subtitle}
    >
      <.form
        for={@form}
        id={@id}
        phx-submit={@event}
        phx-change="validate_cable"
        class="space-y-1"
      >
        <%!-- Endpoints carry the meaningful interface identity, so each select gets the
        full form width instead of a half column that clips the placeholder and options. --%>
        <.input
          field={@form[:interface_a_id]}
          type="select"
          label="First endpoint"
          options={@interface_options}
        />
        <.input
          field={@form[:interface_b_id]}
          type="select"
          label="Second endpoint"
          options={@interface_options}
        />
        <.input
          field={@form[:cable_type]}
          type="text"
          label="Cable type (optional)"
          placeholder="cat6a"
        />
        <.input field={@form[:label]} type="text" label="Label (optional)" />
      </.form>
      <:footer>
        <.button type="button" phx-click={hide_overlay(@panel_id)}>Cancel</.button>
        <.button
          id={@button_id}
          type="submit"
          form={@id}
          variant="primary"
          phx-disable-with="Saving…"
        >
          {@button_label}
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  defp assert_form, do: cable_form(:cable)
  defp plan_form, do: cable_form(:plan)

  defp cable_form(as) do
    to_form(
      %{"interface_a_id" => "", "interface_b_id" => "", "cable_type" => "", "label" => ""},
      as: as
    )
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-edge bg-surface px-4 py-3">
      <div class="flex items-center gap-1.5 text-xs font-medium text-fg-muted">
        <.icon name={@icon} class="size-4 text-fg-subtle" />
        <p>{@label}</p>
      </div>
      <p class="mt-1 font-mono text-xl font-semibold tabular-nums text-fg">{@value}</p>
    </div>
    """
  end

  defp format_length(value, unit) do
    "#{Decimal.to_string(value)} #{unit}"
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp mutation_error(:forbidden), do: "You are not allowed to manage cabling"
  defp mutation_error(:identical_cable_endpoints), do: "A cable needs two distinct endpoints"
  defp mutation_error(:cable_endpoints_required), do: "Select both cable endpoints"

  defp mutation_error(:cable_endpoint_not_physical),
    do: "Both endpoints must be physical ethernet interfaces"

  defp mutation_error(%Ecto.Changeset{} = changeset), do: first_error(changeset)
  defp mutation_error(_reason), do: "The cable change could not be applied"

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "The cable change could not be applied"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
