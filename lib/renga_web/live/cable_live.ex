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
         |> load_cables()}

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
         |> load_cables()}

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
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:cables}>
      <main id="cables" class="space-y-7">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Layer 2 inventory
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Cables</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Desired plans, attributed claims, and the reconciled current cable stay separate.
              Neighbor evidence can propose a claim but never creates cabling.
            </p>
          </div>
          <div :if={@interface} class="flex flex-col items-start gap-2 lg:items-end">
            <span class="inline-flex items-center gap-2 rounded-lg border border-base-content/15 bg-base-100 px-3 py-2 text-xs font-medium">
              <.icon name="hero-funnel" class="size-3.5 text-base-content/55" />
              <span class="font-mono">{@interface.name}</span>
              <span class="text-base-content/55">· {@interface_resource.name}</span>
            </span>
            <.link
              id="cables-clear-interface"
              navigate={~p"/network/cables"}
              class="inline-flex items-center gap-1 text-xs font-medium text-base-content/55 transition hover:text-orange-600"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Clear interface filter
            </.link>
          </div>
        </header>

        <section class="grid gap-3 sm:grid-cols-3">
          <.summary_card label="Current cables" value={@cable_count} icon="hero-link" />
          <.summary_card label="Planned cables" value={@plan_count} icon="hero-map" />
          <.summary_card label="Claims" value={@assertion_count} icon="hero-document-check" />
        </section>

        <section
          id="current-cables"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">Current cables</h2>
              <p class="mt-1 text-xs text-base-content/55">
                Reconciled from confirmed claims. Each endpoint carries at most one current cable.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:text-emerald-400">
              Confirmed
            </span>
          </div>

          <ul id="cables-list" phx-update="stream" class="mt-5 space-y-3">
            <li
              id="cables-empty"
              class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
            >
              No current cable is confirmed in this view.
            </li>
            <li
              :for={{dom_id, cable} <- @streams.cables}
              id={dom_id}
              data-cable-type={cable.cable_type}
              class="rounded-xl bg-base-200/60 px-4 py-4"
            >
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0 space-y-2">
                  <p class="flex flex-wrap items-center gap-2 text-sm">
                    <.endpoint_link interface={cable.interface_a} />
                    <.icon name="hero-link" class="size-3.5 shrink-0 text-base-content/50" />
                    <.endpoint_link interface={cable.interface_b} />
                  </p>
                  <p class="flex flex-wrap items-center gap-2 text-xs text-base-content/55">
                    <span :if={cable.color} class="inline-flex items-center gap-1.5">
                      <span
                        class="inline-block size-3 rounded-full border border-base-content/15"
                        style={"background-color: #{cable.color}"}
                      />
                      {cable.color}
                    </span>
                    <span :if={cable.cable_type}>{cable.cable_type}</span>
                    <span :if={cable.length_value}>
                      {format_length(cable.length_value, cable.length_unit)}
                    </span>
                    <span :if={cable.label}>“{cable.label}”</span>
                    <span>asserted {format_time(cable.last_asserted_at)}</span>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-2 self-start">
                  <span class={status_class(cable.status)}>{cable.status}</span>
                  <button
                    :if={@can_manage?}
                    id={"retract-cable-#{cable.id}"}
                    type="button"
                    phx-click="retract_cable"
                    phx-value-id={cable.id}
                    data-confirm="Retract this cable and release its endpoints?"
                    class="rounded-lg border border-rose-500/30 px-3 py-1.5 text-xs font-semibold text-rose-600 transition hover:bg-rose-500/10"
                  >
                    Retract
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </section>

        <section
          id="cable-plans"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">Cable plans</h2>
              <p class="mt-1 text-xs text-base-content/55">
                Desired connectivity only. A plan never reserves an endpoint and can disagree
                with current cabling without replacing it.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold text-sky-700 dark:text-sky-400">
              Desired
            </span>
          </div>

          <ul id="plans-list" phx-update="stream" class="mt-5 space-y-3">
            <li
              id="plans-empty"
              class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
            >
              No cable plan recorded in this view.
            </li>
            <li
              :for={{dom_id, plan} <- @streams.plans}
              id={dom_id}
              data-plan-status={plan.status}
              class="flex flex-col gap-3 rounded-xl bg-base-200/60 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0 space-y-2">
                <p class="flex flex-wrap items-center gap-2 text-sm">
                  <.endpoint_link interface={plan.interface_a} />
                  <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-base-content/50" />
                  <.endpoint_link interface={plan.interface_b} />
                </p>
                <p class="flex flex-wrap items-center gap-2 text-xs text-base-content/55">
                  <span :if={plan.cable_type}>{plan.cable_type}</span>
                  <span :if={plan.label}>“{plan.label}”</span>
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-2 self-start sm:self-auto">
                <span class={status_class(plan.status)}>{plan.status}</span>
                <button
                  :if={@can_manage?}
                  id={"delete-plan-#{plan.id}"}
                  type="button"
                  phx-click="delete_plan"
                  phx-value-id={plan.id}
                  data-confirm="Remove this cable plan?"
                  class="rounded-lg border border-base-content/15 px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:border-rose-500/40 hover:text-rose-600"
                >
                  Remove
                </button>
              </div>
            </li>
          </ul>
        </section>

        <div :if={@can_manage?} class="grid gap-4 xl:grid-cols-2">
          <.action_form
            id="assert-cable-form"
            title="Confirm current cable"
            subtitle="Records an operator assertion that becomes authoritative cabling for these endpoints."
            button_id="assert-cable"
            button_label="Confirm cable"
            form={@assert_form}
            event="assert_cable"
            interface_options={@interface_options}
          />
          <.action_form
            id="plan-cable-form"
            title="Plan desired cable"
            subtitle="Records desired connectivity without reserving endpoints or replacing current cabling."
            button_id="plan-cable"
            button_label="Save plan"
            form={@plan_form}
            event="plan_cable"
            interface_options={@interface_options}
          />
        </div>

        <section
          id="cable-claims"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-semibold tracking-tight">Cable claims</h2>
              <p class="mt-1 text-xs text-base-content/55">
                Append-only attributed claims, newest first. Proposals from neighbor evidence are
                listed here but never reconcile into current cabling.
              </p>
            </div>
            <span class="shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55">
              History
            </span>
          </div>

          <ul id="claims-list" phx-update="stream" class="mt-5 space-y-2">
            <li
              id="claims-empty"
              class="hidden rounded-xl border border-dashed border-base-content/15 p-6 text-center text-sm text-base-content/55 only:block"
            >
              No cable claim recorded in this view.
            </li>
            <li
              :for={{dom_id, assertion} <- @streams.assertions}
              id={dom_id}
              data-claim-kind={assertion.kind}
              data-claim-action={assertion.action}
              class="flex flex-col gap-2 rounded-xl bg-base-200/60 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="flex min-w-0 flex-wrap items-center gap-2 text-xs">
                <span class={claim_class(assertion)}>{claim_label(assertion)}</span>
                <span class="font-mono text-base-content/60">
                  {endpoint_names(assertion)}
                </span>
              </div>
              <span class="shrink-0 self-start font-mono text-xs text-base-content/55 sm:self-auto">
                {format_time(assertion.asserted_at)}
              </span>
            </li>
          </ul>
        </section>
      </main>
    </Layouts.app>
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

  defp claim_class(%{kind: "neighbor_evidence"}) do
    "shrink-0 rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-semibold text-amber-700 dark:text-amber-400"
  end

  defp claim_class(%{action: "retract"}) do
    "shrink-0 rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-semibold text-rose-700 dark:text-rose-400"
  end

  defp claim_class(_assertion) do
    "shrink-0 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:text-emerald-400"
  end

  attr :interface, :any, required: true

  defp endpoint_link(assigns) do
    ~H"""
    <span class="inline-flex min-w-0 items-center gap-1.5">
      <span class="truncate font-mono text-sm font-medium">{@interface.name}</span>
      <.link
        navigate={~p"/inventory/resources/#{@interface.resource_id}"}
        class="truncate text-xs text-base-content/60 transition hover:text-orange-600"
      >
        {@interface.resource.name}
      </.link>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :button_id, :string, required: true
  attr :button_label, :string, required: true
  attr :form, :any, required: true
  attr :event, :string, required: true
  attr :interface_options, :list, required: true

  defp action_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-submit={@event}
      phx-change="validate_cable"
      class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
    >
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="font-semibold tracking-tight">{@title}</h2>
          <p class="mt-1 text-xs text-base-content/55">{@subtitle}</p>
        </div>
        <span class="shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold text-base-content/55">
          Owner/Admin
        </span>
      </div>
      <div class="mt-6 grid gap-4 sm:grid-cols-2">
        <%!-- Endpoints carry the meaningful interface identity, so each select gets the
        full form width instead of a half column that clips the placeholder and options. --%>
        <div class="sm:col-span-2">
          <.input
            field={@form[:interface_a_id]}
            type="select"
            label="First endpoint"
            options={@interface_options}
            class={input_class()}
          />
        </div>
        <div class="sm:col-span-2">
          <.input
            field={@form[:interface_b_id]}
            type="select"
            label="Second endpoint"
            options={@interface_options}
            class={input_class()}
          />
        </div>
        <.input
          field={@form[:cable_type]}
          type="text"
          label="Cable type (optional)"
          placeholder="cat6a"
          class={input_class()}
        />
        <.input
          field={@form[:label]}
          type="text"
          label="Label (optional)"
          class={input_class()}
        />
      </div>
      <div class="mt-5 flex justify-end">
        <button
          id={@button_id}
          type="submit"
          phx-disable-with="Saving…"
          class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
        >
          {@button_label}
        </button>
      </div>
    </.form>
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

  defp status_class("connected") do
    "shrink-0 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold capitalize text-emerald-700 dark:text-emerald-400"
  end

  defp status_class(_status) do
    "shrink-0 rounded-full bg-base-content/[0.07] px-2.5 py-1 text-xs font-semibold capitalize text-base-content/55"
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm">
      <div class="flex items-center gap-2 text-base-content/45">
        <.icon name={@icon} class="size-4" />
        <p class="text-xs font-semibold uppercase tracking-wider">{@label}</p>
      </div>
      <p class="mt-3 text-2xl font-semibold tracking-tight">{@value}</p>
    </div>
    """
  end

  defp format_length(value, unit) do
    "#{Decimal.to_string(value)} #{unit}"
  end

  defp input_class do
    "h-10 w-full rounded-lg border border-base-content/15 bg-base-100 px-3 text-sm font-medium outline-none transition focus:border-orange-500 focus:ring-2 focus:ring-orange-500/20"
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
