defmodule RengaWeb.ResourceHardwareLive do
  @moduledoc """
  A resource's Hardware tab (RFD 8, "Editing hardware components").

  Expected and observed CPUs, memory, and disks are compared slot by slot
  (`Renga.Catalog.HardwareComparison`). Each slot is a match, missing, not
  expected, or changed on this resource; runs of matching slots collapse
  so the ones that need attention stand out.

  Selecting a slot (`?component=`) opens a panel with its expected and
  observed part that asks what happened instead of offering raw edits:

    * "It is out temporarily" accepts the empty slot until a date; the
      expectation stays. Any member.
    * "A replacement was installed" records the part as confirmed; the
      finding closes once a collector reports it. Any member.
    * "This resource should expect something else" changes this resource
      only. Owners and admins apply it; members request it.

  The chosen answer is in the URL too (`?intent=`), so the panel survives a
  reload. The catalog assignment sits in the aside; module bays and
  inventory-only parts follow the comparison.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents
  import RengaWeb.RequestComponents, only: [pending_request: 1]

  alias Renga.Catalog
  alias Renga.Catalog.ComponentMatch
  alias Renga.Catalog.ExpectedComponent
  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Requests
  alias RengaWeb.Format

  @reload_after_ms 400
  @intents ~w(gap replacement expect restore)a
  @part_fields ~w(part_number model)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)
    resource = Inventory.get_operational_resource!(scope, id)

    {:ok,
     socket
     |> assign(
       resource: resource,
       reload_timer: nil,
       can_author?: Catalog.catalog_author?(scope),
       can_change_expectations?: Catalog.can_change_expectations?(scope),
       can_request?: Requests.can_request?(scope),
       component_param: nil,
       intent_param: nil
     )
     |> load_hardware()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(component_param: params["component"], intent_param: params["intent"])
     |> assign_selection()
     |> reset_forms()}
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
    {:noreply, socket |> assign(:reload_timer, nil) |> load_hardware() |> assign_selection()}
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
            {:noreply, socket |> put_flash(:info, "Hardware type assigned") |> reload()}

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
          {:noreply, socket |> put_flash(:info, "Hardware type assignment cleared") |> reload()}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to manage hardware")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, assignment_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, assignment_error(:unsupported_resource_kind))}
    end
  end

  def handle_event("accept_gap", %{"gap" => params}, socket) do
    with_intent(socket, :gap, fn row ->
      %{current_scope: scope, resource: resource} = socket.assigns

      attrs = %{
        "exception_reason" => params["reason"] || "",
        "exception_expires_at" => end_of_day(params["until"])
      }

      case Findings.accept_component_gap(scope, resource.id, row.resolution_key, attrs) do
        {:ok, workflow} ->
          done(socket, "#{row.label} is out until #{date(workflow.exception_expires_at)}")

        {:error, %Ecto.Changeset{errors: errors}} ->
          form = to_form(params, as: :gap, errors: Enum.map(errors, &gap_error/1))
          {:noreply, assign(socket, :gap_form, form)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to record this")}
      end
    end)
  end

  def handle_event("confirm_replacement", %{"replacement" => params}, socket) do
    with_intent(socket, :replacement, fn row ->
      %{current_scope: scope, resource: resource} = socket.assigns

      case Catalog.confirm_replacement(scope, resource.id, expectation_ref(row.expected), params) do
        {:ok, _confirmation} ->
          done(socket, "Replacement recorded for #{row.label}")

        {:error, %Ecto.Changeset{errors: errors}} ->
          form = to_form(params, as: :replacement, errors: errors)
          {:noreply, assign(socket, :replacement_form, form)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to record this")}
      end
    end)
  end

  def handle_event("change_expect", %{"expect" => params}, socket) do
    {:noreply, assign(socket, :expect_form, to_form(params, as: :expect))}
  end

  def handle_event("change_expectation", %{"expect" => params}, socket) do
    with_intent(socket, :expect, fn row ->
      change = expectation_change(row, params)

      if change["action"] == "alter" and get_in(change, ["changes", "attributes"]) == %{} do
        errors = [part_number: {"enter the part number or model it should expect", []}]
        {:noreply, assign(socket, :expect_form, to_form(params, as: :expect, errors: errors))}
      else
        submit_expectation(socket, row, change, params, :expect_form, :expect)
      end
    end)
  end

  # Owners and admins give no reason, so their form posts no fields.
  def handle_event("restore_expectation", params, socket) do
    params = Map.get(params, "restore", %{})

    with_intent(socket, :restore, fn row ->
      change = %{
        "action" => "restore",
        "exception_id" => row.expected.exception_id,
        "component_template_id" => row.expected.component_template_id,
        "kind" => row.expected.kind,
        "name" => row.expected.name
      }

      submit_expectation(socket, row, change, params, :restore_form, :restore)
    end)
  end

  def handle_event("withdraw_request", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Requests.Request{} = request <- Requests.get_request(scope, id),
         {:ok, _request} <- Requests.withdraw(scope, request) do
      {:noreply, socket |> put_flash(:info, "Request withdrawn") |> reload()}
    else
      _error ->
        {:noreply, socket |> put_flash(:error, "That request is no longer open") |> reload()}
    end
  end

  # The gap form names its fields after what they ask, not the workflow's.
  defp gap_error({:exception_reason, error}), do: {:reason, error}
  defp gap_error({:exception_expires_at, error}), do: {:until, error}
  defp gap_error(other), do: other

  # Owners and admins change the expectation now; members ask for it.
  defp submit_expectation(socket, row, change, params, form_key, as) do
    %{current_scope: scope, resource: resource} = socket.assigns

    result =
      if socket.assigns.can_change_expectations? do
        apply_expectation(scope, resource.id, change)
      else
        Requests.request_expectation(scope, resource, change, %{"reason" => params["reason"]})
      end

    case result do
      {:ok, %Requests.Request{}} ->
        done(socket, "Change requested for #{row.label}; an owner or admin will review it")

      {:ok, _applied} ->
        done(socket, "#{row.label} now expects what you chose")

      {:error, %Ecto.Changeset{errors: errors}} ->
        errors = Enum.map(errors, fn {_field, error} -> {:reason, error} end)
        {:noreply, assign(socket, form_key, to_form(params, as: as, errors: errors))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to change expectations")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "That slot changed; review it and try again")
         |> reload()}
    end
  end

  defp apply_expectation(scope, resource_id, %{"action" => "restore"} = change),
    do: Catalog.delete_expected_component_exception(scope, resource_id, change["exception_id"])

  defp apply_expectation(scope, resource_id, %{"action" => "add"} = change),
    do:
      Catalog.put_expected_component_exception(
        scope,
        resource_id,
        Map.take(change, ~w(action kind name changes))
      )

  defp apply_expectation(scope, resource_id, change),
    do:
      Catalog.put_expected_component_exception(
        scope,
        resource_id,
        Map.take(change, ~w(action component_template_id changes))
      )

  # Runs `fun` with the selected slot when `intent` is one it offers, so a
  # forged event cannot act on a slot or answer the page did not show.
  defp with_intent(socket, intent, fun) do
    %{selected: row, intents: intents} = socket.assigns
    if row && intent in intents, do: fun.(row), else: {:noreply, socket}
  end

  defp done(socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> load_hardware()
     |> push_patch(to: ~p"/inventory/#{socket.assigns.resource}/hardware")}
  end

  defp reload(socket), do: socket |> load_hardware() |> assign_selection()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:inventory}
      content_class="p-0"
    >
      <.resource_frame resource={@resource} tab={:hardware} hardware?={@hardware_assignable?}>
        <div id="resource-hardware" class="space-y-8">
          <p id="hardware-summary" class="text-sm text-fg-muted">
            <%= if @assignment do %>
              <.summary counts={@comparison.counts} />
            <% else %>
              Assign a hardware type to compare what this resource should have with what
              collectors report.
            <% end %>
            Open findings are in the <.link
              navigate={~p"/inbox?#{[resource: @resource.id]}"}
              class="text-link hover:underline"
            >Inbox</.link>.
          </p>

          <div id="hardware-comparison" class="space-y-6">
            <p
              :if={@comparison.sections == []}
              id="hardware-comparison-empty"
              class="rounded-lg border border-dashed border-edge px-4 py-10 text-center text-sm text-fg-muted"
            >
              No CPUs, memory, or disks are expected or reported yet.
            </p>
            <.comparison_section
              :for={section <- @comparison.sections}
              section={section}
              resource={@resource}
              selected={@selected}
              requests={@expectation_requests}
            />
          </div>

          <.other_expected
            :if={@comparison.other_expected != []}
            components={@comparison.other_expected}
          />

          <section id="module-inventory" aria-labelledby="module-inventory-title" class="space-y-2">
            <.section_title id="module-inventory-title" title="Module bays">
              Desired modules next to what is installed
            </.section_title>
            <div
              id="module-bays-list"
              phx-update="stream"
              class="divide-y divide-line rounded-lg border border-edge bg-surface"
            >
              <p
                id="module-bays-empty"
                class="hidden px-4 py-6 text-center text-sm text-fg-muted only:block"
              >
                No module bays are registered for this resource.
              </p>
              <div
                :for={{dom_id, bay_state} <- @streams.module_bays}
                id={dom_id}
                class="grid gap-x-4 gap-y-1 px-3 py-2.5 text-sm sm:grid-cols-[10rem_minmax(0,1fr)_minmax(0,1fr)_auto] sm:items-center"
              >
                <div class="min-w-0">
                  <p class="truncate font-medium">{bay_state.bay.label || bay_state.bay.name}</p>
                  <p class="font-mono text-xs text-fg-muted">
                    {bay_state.bay.position || "No position"}
                  </p>
                </div>
                <p class="min-w-0 truncate">
                  <span class="text-fg-muted">Desired</span>
                  {module_type_label(bay_state.desired && bay_state.desired.module_type)}
                </p>
                <p class="min-w-0 truncate">
                  <span class="text-fg-muted">Current</span>
                  {current_module_label(bay_state.current)}
                </p>
                <p class="text-xs text-fg-muted">
                  {length(bay_state.events)} installation events
                </p>
              </div>
            </div>
          </section>

          <section id="inventory-items" aria-labelledby="inventory-items-title" class="space-y-2">
            <.section_title id="inventory-items-title" title="Inventory-only parts">
              Parts recorded for the asset record, outside topology
            </.section_title>
            <div
              id="inventory-items-list"
              phx-update="stream"
              class="divide-y divide-line rounded-lg border border-edge bg-surface"
            >
              <p
                id="inventory-items-empty"
                class="hidden px-4 py-6 text-center text-sm text-fg-muted only:block"
              >
                No inventory-only parts are registered.
              </p>
              <div
                :for={{dom_id, item} <- @streams.inventory_items}
                id={dom_id}
                class="grid gap-x-4 gap-y-0.5 px-3 py-2.5 text-sm sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] sm:items-center"
              >
                <div class="min-w-0">
                  <p class="truncate font-medium">{item.name}</p>
                  <p class="text-xs text-fg-muted">{Format.humanize(item.kind)}</p>
                </div>
                <p class="min-w-0 truncate text-xs text-fg-muted">
                  {item.position || "No position"} · {(item.parent && item.parent.name) ||
                    "Resource root"}
                </p>
                <p class="text-xs capitalize text-fg-muted">{item.status}</p>
              </div>
            </div>
          </section>
        </div>

        <:aside>
          <.assignment
            assignment={@assignment}
            assignable?={@hardware_assignable?}
            can_manage?={@can_manage_hardware?}
            form={@hardware_form}
            options={@hardware_type_options}
          />
        </:aside>
      </.resource_frame>

      <.slot_panel
        :if={@selected}
        row={@selected}
        resource={@resource}
        intents={@intents}
        intent={@intent}
        request={@selected_request}
        can_change?={@can_change_expectations?}
        can_author?={@can_author?}
        current_user_id={@current_scope.user.id}
        gap_form={@gap_form}
        replacement_form={@replacement_form}
        expect_form={@expect_form}
        restore_form={@restore_form}
      />
    </Layouts.app>
    """
  end

  attr :counts, :map, required: true

  defp summary(assigns) do
    counts = assigns.counts

    parts =
      [
        {counts.match, "match", "text-fg"},
        {counts.missing, "missing", "text-crit"},
        {counts.not_expected, "not expected", "text-fg"},
        {counts.local_change, "changed on this resource", "text-warn-text"}
      ]
      |> Enum.filter(fn {count, label, _class} -> count > 0 or label == "match" end)
      |> Enum.with_index()

    assigns = assign(assigns, total: counts |> Map.values() |> Enum.sum(), parts: parts)

    ~H"""
    <span class="font-mono tabular-nums text-fg">{@total}</span>
    slots:
    <span :for={{{count, label, class}, index} <- @parts}>{if index > 0, do: ", "}<span class={[
        "font-mono tabular-nums",
        class
      ]}>{count}</span> {label}</span>.
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block

  defp section_title(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
      <h2 id={@id} class="text-sm font-semibold text-fg">{@title}</h2>
      <p :if={@inner_block != []} class="text-xs text-fg-muted">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :resource, :any, required: true
  attr :selected, :map, default: nil
  attr :requests, :map, required: true

  defp comparison_section(assigns) do
    ~H"""
    <section
      id={"hardware-#{@section.kind}"}
      aria-labelledby={"hardware-#{@section.kind}-title"}
      class="space-y-2"
    >
      <.section_title id={"hardware-#{@section.kind}-title"} title={kind_title(@section.kind)}>
        {section_counts(@section)}
      </.section_title>
      <div role="table" class="rounded-lg border border-edge bg-surface">
        <div
          role="row"
          class="hidden grid-cols-[9rem_minmax(0,1fr)_minmax(0,1fr)_11rem] gap-x-3 border-b border-edge px-3 py-1.5 text-xs text-fg-muted sm:grid"
        >
          <span role="columnheader">Slot</span>
          <span role="columnheader">Expected</span>
          <span role="columnheader">Observed</span>
          <span role="columnheader">State</span>
        </div>
        <div role="rowgroup" class="divide-y divide-line">
          <%= for group <- @section.groups do %>
            <%= case group do %>
              <% {:run, rows} -> %>
                <.match_run rows={rows} resource={@resource} selected={@selected} />
              <% {:row, row} -> %>
                <.slot_row
                  row={row}
                  resource={@resource}
                  selected={@selected}
                  request={@requests[request_field(row)]}
                />
            <% end %>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :resource, :any, required: true
  attr :selected, :map, default: nil

  # A run of matching slots folds into one line; the slots stay in the page
  # so opening the run needs no round trip.
  defp match_run(assigns) do
    ~H"""
    <details
      id={"run-#{slot_id(hd(@rows).key)}"}
      class="group"
      open={Enum.any?(@rows, &(@selected && &1.key == @selected.key))}
    >
      <summary class="flex min-h-tap cursor-pointer list-none items-center gap-2 px-3 py-2 text-sm transition-colors hover:bg-sunken/60 focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring sm:min-h-9 [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-fg-muted transition-transform group-open:rotate-90"
        />
        <span class="truncate font-mono">{hd(@rows).label} – {List.last(@rows).label}</span>
        <span class="shrink-0 text-fg-muted">{length(@rows)} match</span>
        <span class="ml-auto hidden truncate text-xs text-fg-muted sm:block">
          {run_part(@rows)}
        </span>
        <.icon name="hero-check-circle-mini" class="size-4 shrink-0 text-ok" />
      </summary>
      <div class="divide-y divide-line border-t border-line">
        <.slot_row :for={row <- @rows} row={row} resource={@resource} selected={@selected} />
      </div>
    </details>
    """
  end

  attr :row, :map, required: true
  attr :resource, :any, required: true
  attr :selected, :map, default: nil
  attr :request, :any, default: nil

  defp slot_row(assigns) do
    assigns =
      assign(assigns, :selected?, assigns.selected && assigns.selected.key == assigns.row.key)

    ~H"""
    <.link
      id={slot_id(@row.key)}
      role="row"
      patch={slot_path(@resource, @row.key)}
      data-state={@row.state}
      aria-current={@selected? && "true"}
      class={[
        "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-0.5 px-3 py-2 text-sm transition-colors",
        "sm:min-h-9 sm:grid-cols-[9rem_minmax(0,1fr)_minmax(0,1fr)_11rem]",
        "focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-inset focus-visible:ring-ring",
        if(@selected?, do: "bg-accent-tint", else: "hover:bg-sunken/60")
      ]}
    >
      <span role="cell" class="truncate font-mono">{@row.label}</span>
      <span role="cell" class="justify-self-end sm:order-last sm:justify-self-start">
        <.slot_state row={@row} />
        <span :if={@request} class="ml-1 text-xs text-fg-muted" title="A change is requested">
          <.icon name="hero-chat-bubble-left-ellipsis-mini" class="size-3.5 align-[-2px]" />
          <span class="sr-only">Change requested</span>
        </span>
      </span>
      <span role="cell" class="col-span-2 min-w-0 truncate text-xs sm:col-span-1 sm:text-sm">
        <span class="text-fg-muted sm:hidden">Expected </span>
        <.expected_part row={@row} />
      </span>
      <span role="cell" class="col-span-2 min-w-0 truncate text-xs sm:col-span-1 sm:text-sm">
        <span class="text-fg-muted sm:hidden">Observed </span>
        <.observed_part row={@row} />
      </span>
    </.link>
    """
  end

  attr :row, :map, required: true

  defp expected_part(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@row.expected) -> %>
        <span class="text-fg-subtle">Nothing</span>
      <% @row.expected.suppressed -> %>
        <span class="text-fg-muted line-through">{part_label(@row.expected)}</span>
      <% true -> %>
        <span class="font-mono">{part_label(@row.effective)}</span>
        <span :if={not @row.expected.required} class="text-xs text-fg-muted">optional</span>
    <% end %>
    """
  end

  attr :row, :map, required: true

  defp observed_part(assigns) do
    ~H"""
    <%= cond do %>
      <% @row.actual -> %>
        <span class={["font-mono", @row.differences != %{} && "text-warn-text"]}>
          <span :if={@row.differences != %{}} aria-hidden="true">≠ </span>{part_label(@row.actual)}
        </span>
      <% :ambiguous in @row.reasons -> %>
        <span class="text-fg-muted">{@row.differences["candidates"]} possible parts</span>
      <% true -> %>
        <span class="text-fg-subtle">Nothing reported</span>
    <% end %>
    """
  end

  attr :row, :map, required: true

  # The state reads without color: each has its own icon and words.
  defp slot_state(assigns) do
    assigns = assign(assigns, state_chip(assigns.row))

    ~H"""
    <span class={["inline-flex items-center gap-1 whitespace-nowrap text-xs font-medium", @class]}>
      <.icon name={@icon} class="size-3.5 shrink-0" />{@text}
    </span>
    """
  end

  defp state_chip(%{state: :missing, gap: %{exception_expires_at: until}}) when not is_nil(until),
    do: %{icon: "hero-clock-mini", class: "text-fg-muted", text: "Out until #{date(until)}"}

  defp state_chip(%{state: :match}),
    do: %{icon: "hero-check-circle-mini", class: "text-ok", text: "Match"}

  defp state_chip(%{state: :missing, reasons: [:replacement_pending]}),
    do: %{icon: "hero-arrow-path-mini", class: "text-info", text: "Replacement pending"}

  defp state_chip(%{state: :missing, expected: %{required: false}}),
    do: %{icon: "hero-minus-circle-mini", class: "text-fg-muted", text: "Empty"}

  defp state_chip(%{state: :missing}),
    do: %{icon: "hero-x-circle-mini", class: "text-crit", text: "Missing"}

  defp state_chip(%{state: :not_expected}),
    do: %{icon: "hero-plus-circle-mini", class: "text-info", text: "Not expected"}

  defp state_chip(%{reasons: reasons}) do
    if :replacement_pending in reasons do
      %{icon: "hero-arrow-path-mini", class: "text-info", text: "Replacement pending"}
    else
      text =
        cond do
          :suppressed in reasons -> "Not expected here"
          :ambiguous in reasons -> "Ambiguous"
          :drift in reasons -> "Different part"
          true -> "Changed here"
        end

      %{icon: "hero-pencil-square-mini", class: "text-warn-text", text: text}
    end
  end

  attr :components, :list, required: true

  # Collectors report only CPUs, memory, and disks, so other expectations
  # (interfaces, power ports, bays) are listed without a comparison.
  defp other_expected(assigns) do
    ~H"""
    <section id="other-expected" aria-labelledby="other-expected-title" class="space-y-2">
      <.section_title id="other-expected-title" title="Also expected">
        Not reported by collectors, so not compared
      </.section_title>
      <ul class="divide-y divide-line rounded-lg border border-edge bg-surface">
        <li
          :for={component <- @components}
          id={"expected-component-#{component.id}"}
          class="flex items-center gap-3 px-3 py-2 text-sm"
        >
          <span class="min-w-0 flex-1 truncate">{component.label || component.name}</span>
          <span class="font-mono text-xs text-fg-muted">{component.position}</span>
          <span class="w-24 text-right text-xs text-fg-muted">
            {if component.suppressed, do: "not expected here", else: Format.humanize(component.kind)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :assignment, :any, required: true
  attr :assignable?, :boolean, required: true
  attr :can_manage?, :boolean, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true

  defp assignment(assigns) do
    ~H"""
    <section id="hardware-assignment" class="space-y-3">
      <.properties id="hardware-assignment-properties" title="Hardware type">
        <:item label="Type" blank={is_nil(@assignment)} placeholder="Unclassified">
          <.link
            :if={@assignment}
            navigate={~p"/catalog/hardware-types/#{@assignment.hardware_type.id}"}
            class="text-link hover:underline"
          >
            {@assignment.hardware_type.model}
          </.link>
        </:item>
        <:item :if={@assignment} label="Revision">
          <span class="font-mono">{@assignment.catalog_type_revision.revision}</span>
        </:item>
        <:item :if={@assignment} label="Assigned by">
          {assignment_origin(@assignment.origin)}
        </:item>
      </.properties>

      <div :if={@can_manage?}>
        <.form
          for={@form}
          id="hardware-assignment-form"
          phx-submit="assign_hardware_type"
          class="space-y-2"
        >
          <.input
            field={@form[:hardware_type_id]}
            type="select"
            label={if(@assignment, do: "Change type", else: "Assign a type")}
            prompt="Select a published type"
            options={@options}
          />
          <div class="flex items-center gap-2">
            <.button
              id="hardware-assignment-save"
              size="sm"
              variant="primary"
              phx-disable-with="Assigning…"
            >
              Assign
            </.button>
            <.button
              :if={@assignment}
              id="hardware-assignment-clear"
              type="button"
              size="sm"
              variant="ghost"
              phx-click="clear_hardware_type"
              data-confirm="Clear the hardware type and what this resource expects?"
            >
              Clear
            </.button>
          </div>
        </.form>
      </div>
      <p :if={@assignable? and !@can_manage?} id="hardware-read-only" class="text-xs text-fg-muted">
        Owners, admins, and members assign hardware types.
      </p>
      <p :if={!@assignable?} id="hardware-unsupported" class="text-xs text-fg-muted">
        This resource kind does not take a hardware type.
      </p>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :resource, :any, required: true
  attr :intents, :list, required: true
  attr :intent, :atom, default: nil
  attr :request, :any, default: nil
  attr :can_change?, :boolean, required: true
  attr :can_author?, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :gap_form, :any, required: true
  attr :replacement_form, :any, required: true
  attr :expect_form, :any, required: true
  attr :restore_form, :any, required: true

  defp slot_panel(assigns) do
    ~H"""
    <.side_panel
      id="slot-panel"
      title={@row.label}
      description={state_description(@row)}
      show
      on_cancel={JS.patch(~p"/inventory/#{@resource}/hardware")}
    >
      <div class="space-y-6">
        <.slot_fields row={@row} />
        <.slot_notes row={@row} />
        <.slot_evidence :if={@row.actual} actual={@row.actual} />

        <.pending_request
          :if={@request}
          id="slot-request"
          request={@request}
          current_user_id={@current_user_id}
        />

        <section :if={@intents != []} id="slot-intents" aria-labelledby="slot-intents-title">
          <h3 id="slot-intents-title" class="mb-2 text-xs font-medium text-fg-muted">
            What happened?
          </h3>
          <ul class="space-y-1.5">
            <li :for={intent <- @intents}>
              <.link
                id={"slot-intent-#{intent}"}
                patch={slot_path(@resource, @row.key, if(intent != @intent, do: intent))}
                aria-current={intent == @intent && "true"}
                class={[
                  "flex min-h-tap items-start gap-2.5 rounded-lg border px-3 py-2 text-sm transition-colors",
                  "focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring",
                  if(intent == @intent,
                    do: "border-accent bg-accent-tint",
                    else: "border-edge hover:bg-sunken"
                  )
                ]}
              >
                <.icon
                  name={
                    if(intent == @intent, do: "hero-check-circle-mini", else: intent_icon(intent))
                  }
                  class={"mt-0.5 size-4 shrink-0 #{if intent == @intent, do: "text-accent"}"}
                />
                <span class="min-w-0">
                  <span class="block font-medium text-fg">{intent_title(intent, @row)}</span>
                  <span class="block text-xs text-fg-muted">
                    {intent_description(intent, @row, @can_change?)}
                  </span>
                </span>
              </.link>
            </li>
          </ul>
        </section>

        <.gap_form :if={@intent == :gap} form={@gap_form} />
        <.replacement_form :if={@intent == :replacement} form={@replacement_form} />
        <.expect_form
          :if={@intent == :expect}
          form={@expect_form}
          row={@row}
          can_change?={@can_change?}
        />
        <.restore_form
          :if={@intent == :restore}
          form={@restore_form}
          row={@row}
          can_change?={@can_change?}
        />

        <p
          :if={@intents == [] and !@can_author?}
          id="slot-read-only"
          class="text-sm text-fg-muted"
        >
          Owners, admins, and members record what happened to a part.
        </p>
      </div>
    </.side_panel>
    """
  end

  attr :row, :map, required: true

  # Expected and observed side by side, field by field, with the fields
  # that differ marked so drift reads without color.
  defp slot_fields(assigns) do
    assigns = assign(assigns, :fields, field_rows(assigns.row))

    ~H"""
    <section id="slot-fields" aria-label="Expected and observed">
      <div class="grid grid-cols-[6.5rem_minmax(0,1fr)_minmax(0,1fr)] gap-x-3 text-sm">
        <span class="pb-1 text-xs text-fg-muted"></span>
        <span class="pb-1 text-xs font-medium text-fg-muted">Expected</span>
        <span class="pb-1 text-xs font-medium text-fg-muted">Observed</span>
        <%= for field <- @fields do %>
          <span class="border-t border-line py-1.5 text-fg-muted">{field_label(field.field)}</span>
          <span class="truncate border-t border-line py-1.5 font-mono" title={field.expected}>
            {field.expected || "—"}
          </span>
          <span
            id={"slot-field-#{field.field}"}
            data-differs={to_string(field.differs?)}
            class={[
              "truncate border-t border-line py-1.5 font-mono",
              field.differs? && "text-warn-text"
            ]}
            title={field.actual}
          >
            <span :if={field.differs?} aria-hidden="true">≠ </span>{field.actual || "—"}
            <span :if={field.differs?} class="sr-only">(differs)</span>
          </span>
        <% end %>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true

  defp slot_notes(assigns) do
    ~H"""
    <ul :if={notes(@row) != []} id="slot-notes" class="space-y-1.5">
      <li
        :for={{icon, text} <- notes(@row)}
        class="flex gap-2 rounded-md bg-sunken px-3 py-2 text-sm text-fg-muted"
      >
        <.icon name={icon} class="mt-0.5 size-4 shrink-0" />
        <span>{text}</span>
      </li>
    </ul>
    """
  end

  attr :actual, :any, required: true

  defp slot_evidence(assigns) do
    ~H"""
    <section aria-labelledby="slot-evidence-title">
      <h3 id="slot-evidence-title" class="mb-2 text-xs font-medium text-fg-muted">Reported by</h3>
      <ul class="divide-y divide-line rounded-lg border border-edge">
        <li
          :for={match <- @actual.evidence_matches}
          id={"component-evidence-match-#{match.id}"}
          class="flex items-baseline gap-2 px-3 py-2 text-sm"
        >
          <span class="min-w-0 flex-1 truncate">{match.component_evidence.source.name}</span>
          <span class="text-xs text-fg-muted">{Format.humanize(match.match_strategy)}</span>
          <time
            datetime={DateTime.to_iso8601(match.component_evidence.observed_at)}
            title={Format.datetime(match.component_evidence.observed_at)}
            class="font-mono text-xs text-fg-muted"
          >
            {Format.age(match.component_evidence.observed_at)}
          </time>
        </li>
        <li :if={@actual.evidence_matches == []} class="px-3 py-2 text-sm text-fg-muted">
          Last seen {Format.datetime(@actual.last_observed_at)}
        </li>
      </ul>
    </section>
    """
  end

  attr :form, :any, required: true

  defp gap_form(assigns) do
    ~H"""
    <.form for={@form} id="gap-form" phx-submit="accept_gap" class="space-y-1">
      <.input field={@form[:until]} type="date" label="Back by" />
      <.input field={@form[:reason]} type="text" label="Why is it out?" autocomplete="off" />
      <p class="text-xs text-fg-muted">
        The slot still expects its part. Until this date its finding stays out of the queue.
      </p>
      <div class="flex justify-end pt-2">
        <.button id="gap-save" variant="primary" phx-disable-with="Saving…">
          Accept until then
        </.button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true

  defp replacement_form(assigns) do
    ~H"""
    <.form for={@form} id="replacement-form" phx-submit="confirm_replacement" class="space-y-1">
      <.input field={@form[:part_number]} type="text" label="Part number" autocomplete="off" />
      <.input field={@form[:serial_number]} type="text" label="Serial number" autocomplete="off" />
      <.input field={@form[:model]} type="text" label="Model" autocomplete="off" />
      <.input field={@form[:note]} type="text" label="Note" autocomplete="off" />
      <p class="text-xs text-fg-muted">
        This slot expects the new part from now on. Its finding closes when a collector reports it.
      </p>
      <div class="flex justify-end pt-2">
        <.button id="replacement-save" variant="primary" phx-disable-with="Saving…">
          Record replacement
        </.button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :row, :map, required: true
  attr :can_change?, :boolean, required: true

  defp expect_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="expect-form"
      phx-change="change_expect"
      phx-submit="change_expectation"
      class="space-y-1"
    >
      <.input
        :if={@row.state != :not_expected}
        field={@form[:action]}
        type="select"
        label="It should expect"
        options={[{"A different part", "alter"}, {"Nothing in this slot", "suppress"}]}
      />
      <div :if={@form[:action].value != "suppress"}>
        <.input field={@form[:part_number]} type="text" label="Part number" autocomplete="off" />
        <.input field={@form[:model]} type="text" label="Model" autocomplete="off" />
      </div>
      <.input
        :if={!@can_change?}
        field={@form[:reason]}
        type="text"
        label="Why?"
        autocomplete="off"
      />
      <p class="text-xs text-fg-muted">
        Only this resource changes; the catalog and other resources stay as they are.
      </p>
      <div class="flex justify-end pt-2">
        <.button id="expect-save" variant="primary" phx-disable-with="Saving…">
          {if @can_change?, do: "Change expectation", else: "Request change"}
        </.button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :row, :map, required: true
  attr :can_change?, :boolean, required: true

  defp restore_form(assigns) do
    ~H"""
    <.form for={@form} id="restore-form" phx-submit="restore_expectation" class="space-y-1">
      <.input
        :if={!@can_change?}
        field={@form[:reason]}
        type="text"
        label="Why?"
        autocomplete="off"
      />
      <div class="flex justify-end pt-2">
        <.button id="restore-save" variant="primary" phx-disable-with="Saving…">
          {cond do
            @can_change? and is_nil(@row.expected.component_template_id) -> "Stop expecting it"
            @can_change? -> "Use the catalog's expectation"
            true -> "Request change"
          end}
        </.button>
      </div>
    </.form>
    """
  end

  ## Loading

  defp load_hardware(socket) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_operational_resource!(scope, socket.assigns.resource.id)
    hardware_types = Catalog.list_hardware_types(scope)
    assignment = Catalog.get_hardware_assignment(scope, resource.id)
    hardware_assignable? = Catalog.hardware_assignable_resource?(resource)
    comparison = Catalog.hardware_comparison(scope, resource.id)

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
      resource: resource,
      page_title: "#{resource.display_name || resource.name} hardware",
      assignment: assignment,
      comparison: comparison,
      rows:
        for(section <- comparison.sections, row <- section.rows, into: %{}, do: {row.key, row}),
      expectation_requests: Requests.open_requests(scope, resource.id, "expectation"),
      hardware_assignable?: hardware_assignable?,
      can_manage_hardware?: hardware_assignable? and socket.assigns.can_author?,
      hardware_type_options: hardware_type_options(hardware_types),
      hardware_form: hardware_form(assignment)
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

  # The selected slot and answer come from the URL; both are re-resolved
  # when the comparison reloads, so a slot that disappears closes its panel.
  defp assign_selection(socket) do
    selected = Map.get(socket.assigns.rows, socket.assigns.component_param)
    intents = if selected, do: intents(selected, socket.assigns), else: []
    intent = Enum.find(intents, &(Atom.to_string(&1) == socket.assigns.intent_param))

    assign(socket,
      selected: selected,
      intents: intents,
      intent: intent,
      selected_request: selected && socket.assigns.expectation_requests[request_field(selected)]
    )
  end

  # What can be said about a slot depends on its state and the viewer's
  # role: any member records a gap or a replacement; owners and admins
  # change the expectation, and members ask for that unless a request for
  # the slot is already open.
  defp intents(row, assigns) do
    expect? =
      assigns.can_change_expectations? or
        (assigns.can_request? and
           not Map.has_key?(assigns.expectation_requests, request_field(row)))

    row
    |> candidate_intents()
    |> Enum.filter(fn
      intent when intent in [:gap, :replacement] -> assigns.can_author?
      _expectation -> expect?
    end)
  end

  defp candidate_intents(%{state: :not_expected}), do: [:expect]

  defp candidate_intents(%{expected: expected} = row) do
    [
      row.state == :missing and expected.required and not expected.suppressed and :gap,
      not expected.suppressed and :replacement,
      expected.component_template_id && not expected.suppressed && :expect,
      expected.exception_id && :restore
    ]
    |> Enum.filter(&(&1 in @intents))
  end

  defp reset_forms(socket) do
    row = socket.assigns.selected

    assign(socket,
      gap_form:
        to_form(
          %{"until" => Date.to_iso8601(Date.add(Date.utc_today(), 7)), "reason" => ""},
          as: :gap
        ),
      replacement_form: to_form(replacement_defaults(row), as: :replacement),
      expect_form: to_form(expect_defaults(row), as: :expect),
      restore_form: to_form(%{"reason" => ""}, as: :restore)
    )
  end

  # A part that differs from the expectation is most likely the
  # replacement, so the form starts from what the collector reported.
  defp replacement_defaults(%{actual: %{} = actual, differences: differences})
       when differences != %{} do
    %{
      "part_number" => actual.part_number,
      "serial_number" => actual.serial_number,
      "model" => actual.model,
      "note" => ""
    }
  end

  defp replacement_defaults(_row),
    do: %{"part_number" => "", "serial_number" => "", "model" => "", "note" => ""}

  defp expect_defaults(%{actual: %{} = actual, state: state} = row)
       when state == :not_expected or row.differences != %{} do
    %{
      "action" => if(state == :not_expected, do: "add", else: "alter"),
      "part_number" => actual.part_number,
      "model" => actual.model,
      "reason" => ""
    }
  end

  defp expect_defaults(%{effective: %{attributes: attributes}}) do
    %{
      "action" => "alter",
      "part_number" => attributes["part_number"],
      "model" => attributes["model"],
      "reason" => ""
    }
  end

  defp expect_defaults(_row), do: %{"action" => "alter", "reason" => ""}

  ## Expectation changes

  defp expectation_ref(%{component_template_id: id}) when not is_nil(id),
    do: %{"component_template_id" => id}

  defp expectation_ref(%{exception_id: id}), do: %{"exception_id" => id}

  defp expectation_change(%{state: :not_expected, actual: actual} = row, params) do
    %{
      "action" => "add",
      "kind" => actual.kind,
      "name" => actual.name || row.label,
      "changes" =>
        %{"position" => actual.slot || actual.path, "attributes" => part_attributes(params)}
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp expectation_change(%{expected: expected}, %{"action" => "suppress"}) do
    %{
      "action" => "suppress",
      "component_template_id" => expected.component_template_id,
      "name" => expected.name
    }
  end

  defp expectation_change(%{expected: expected}, params) do
    %{
      "action" => "alter",
      "component_template_id" => expected.component_template_id,
      "name" => expected.name,
      "changes" => %{"attributes" => part_attributes(params)}
    }
  end

  defp part_attributes(params) do
    params
    |> Map.take(@part_fields)
    |> Enum.map(fn {field, value} -> {field, String.trim(value || "")} end)
    |> Enum.reject(fn {_field, value} -> value == "" end)
    |> Map.new()
  end

  # The request field for a slot, matching `Renga.Requests.expectation_field/1`.
  defp request_field(%{state: :not_expected} = row),
    do: Requests.expectation_field(expectation_change(row, %{}))

  defp request_field(%{expected: %{component_template_id: id}}) when not is_nil(id),
    do: Requests.expectation_field(%{"action" => "alter", "component_template_id" => id})

  defp request_field(%{expected: expected}),
    do:
      Requests.expectation_field(%{
        "action" => "add",
        "kind" => expected.kind,
        "name" => expected.name
      })

  ## Presentation

  defp slot_path(resource, key, intent \\ nil) do
    query = Enum.reject([component: key, intent: intent], fn {_key, value} -> is_nil(value) end)
    ~p"/inventory/#{resource}/hardware?#{query}"
  end

  defp slot_id(key), do: "slot-" <> String.replace(key, ":", "-")

  defp kind_title("cpu"), do: "Processors"
  defp kind_title("memory"), do: "Memory"
  defp kind_title("disk"), do: "Disks"
  defp kind_title(kind), do: kind |> Format.humanize() |> String.capitalize()

  defp section_counts(section) do
    total = length(section.rows)
    counts = section.counts

    attention =
      [
        {counts[:missing], "missing"},
        {counts[:not_expected], "not expected"},
        {counts[:local_change], "changed"}
      ]
      |> Enum.filter(fn {count, _label} -> count end)
      |> Enum.map(fn {count, label} -> "#{count} #{label}" end)

    Enum.join(["#{total} #{if total == 1, do: "slot", else: "slots"}" | attention], " · ")
  end

  defp run_part(rows) do
    rows |> Enum.map(&part_label(&1.effective)) |> Enum.uniq() |> Enum.join(", ")
  end

  defp part_label(%ExpectedComponent{attributes: attributes, name: name}),
    do: attributes["part_number"] || attributes["model"] || name

  defp part_label(actual), do: actual.part_number || actual.model || actual.name || actual.kind

  defp field_rows(row) do
    attribute_fields = if row.effective, do: Map.keys(row.effective.attributes), else: []

    (~w(part_number model serial_number) ++ Enum.sort(attribute_fields))
    |> Enum.uniq()
    |> Enum.flat_map(fn field ->
      expected = row.effective && row.effective.attributes[field]
      actual = row.actual && ComponentMatch.spec(row.actual, field)

      if is_nil(expected) and is_nil(actual) do
        []
      else
        [
          %{
            field: field,
            expected: format_value(expected),
            actual: format_value(actual),
            differs?: Map.has_key?(row.differences, field)
          }
        ]
      end
    end)
  end

  defp format_value(nil), do: nil
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp format_value(value), do: Jason.encode!(value)

  defp field_label("part_number"), do: "Part number"
  defp field_label("serial_number"), do: "Serial"

  # Catalog attributes name units as suffixes: size_gb reads "Size (GB)".
  defp field_label(field) do
    case Regex.run(~r/^(.+)_(gb|mb|tb|mhz|ghz|w)$/, field) do
      [_field, name, unit] -> "#{field_label(name)} (#{unit_label(unit)})"
      nil -> field |> Format.humanize() |> String.capitalize()
    end
  end

  defp unit_label(unit) when unit in ~w(mhz ghz), do: String.upcase(String.first(unit)) <> "Hz"
  defp unit_label(unit), do: String.upcase(unit)

  defp state_description(%{state: :match}), do: "The expected part is in this slot"
  defp state_description(%{state: :not_expected}), do: "Reported, but nothing expects it"

  defp state_description(%{state: :missing, expected: %{required: false}}),
    do: "Optional and empty"

  defp state_description(%{state: :missing}), do: "Expected, but nothing is reported here"

  defp state_description(%{reasons: reasons}) do
    cond do
      :replacement_pending in reasons ->
        "A replacement is recorded; the old part is still reported"

      :suppressed in reasons ->
        "Not expected on this resource"

      :ambiguous in reasons ->
        "Several reported parts could be in this slot"

      :drift in reasons ->
        "A different part is reported in this slot"

      true ->
        "This resource expects something different from the catalog"
    end
  end

  defp notes(row) do
    [
      row.gap &&
        {"hero-clock-mini",
         "#{if row.gap.exception_expires_at, do: "Out until #{date(row.gap.exception_expires_at)}", else: "Accepted indefinitely"}: “#{row.gap.exception_reason}”"},
      row.confirmation &&
        {"hero-arrow-path-mini", replacement_note(row)},
      :override in row.reasons &&
        {"hero-pencil-square-mini",
         "This resource expects something different from its hardware type."},
      :ambiguous in row.reasons &&
        {"hero-question-mark-circle-mini",
         "#{row.differences["candidates"]} reported parts match this slot or another one. Recording the replacement tells them apart."}
    ]
    |> Enum.filter(& &1)
  end

  defp replacement_note(%{confirmation: confirmation, reasons: reasons}) do
    part =
      [confirmation.part_number, confirmation.model, confirmation.serial_number]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    status =
      if :replacement_pending in reasons,
        do: "waiting for a collector to report it",
        else: "reported"

    "Replacement #{part} recorded #{date(confirmation.confirmed_at)}, #{status}."
  end

  defp intent_icon(:gap), do: "hero-clock-mini"
  defp intent_icon(:replacement), do: "hero-arrow-path-mini"
  defp intent_icon(:expect), do: "hero-pencil-square-mini"
  defp intent_icon(:restore), do: "hero-arrow-uturn-left-mini"

  defp intent_title(:gap, _row), do: "It is out temporarily"
  defp intent_title(:replacement, _row), do: "A replacement was installed"
  defp intent_title(:expect, %{state: :not_expected}), do: "This resource should expect it"
  defp intent_title(:expect, _row), do: "This resource should expect something else"

  defp intent_title(:restore, %{expected: %{suppressed: true}}),
    do: "It should be expected again"

  defp intent_title(:restore, %{expected: %{component_template_id: nil}}),
    do: "This resource should stop expecting it"

  defp intent_title(:restore, _row), do: "Go back to the hardware type's expectation"

  defp intent_description(:gap, _row, _can_change?),
    do: "Accept the empty slot until a date. It is still expected."

  defp intent_description(:replacement, _row, _can_change?),
    do: "Record the new part. The finding closes when a collector reports it."

  defp intent_description(intent, _row, true) when intent in [:expect, :restore],
    do: "Changes this resource only."

  defp intent_description(intent, _row, false) when intent in [:expect, :restore],
    do: "Changes this resource only. An owner or admin reviews the request."

  defp end_of_day(value) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")

  defp assignment_origin("operator"), do: "A person"
  defp assignment_origin(origin), do: Format.humanize(origin) |> String.capitalize()

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

  defp module_type_label(nil), do: "Not assigned"
  defp module_type_label(module_type), do: module_type.model

  defp current_module_label(nil), do: "Not installed"

  defp current_module_label(installation) do
    installation.module.serial_number || installation.module_type.model
  end
end
