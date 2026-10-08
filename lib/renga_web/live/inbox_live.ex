defmodule RengaWeb.InboxLive do
  @moduledoc """
  The Inbox (RFD 8: "What needs me?"): member requests and findings from
  every domain in one place, grouped as Requests, Drift, and Health,
  replacing the separate component, topology, and placement findings pages.
  Owners and admins approve or reject requests from the request panel.

  Reconciliation opens and closes findings; people add judgment in the
  finding panel: assign, snooze, or accept as an exception. All list state
  lives in the URL, including the open finding, so a link reproduces the
  view. The queue re-reads itself when the organization's inventory or a
  finding's workflow changes.

  The finding panel is one of RFD 8's phone-complete tasks: reading a
  finding, assigning, snoozing, and accepting an exception all work at
  390px.
  """
  use RengaWeb, :live_view

  import RengaWeb.RequestComponents

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Findings
  alias Renga.Requests
  alias Renga.Requests.Request
  alias Renga.Inventory.Changes
  alias RengaWeb.Format

  @reload_after_ms 400

  @snoozes [
    {"1h", "1 hour", 3_600},
    {"4h", "4 hours", 4 * 3_600},
    {"1d", "1 day", 86_400},
    {"1w", "1 week", 7 * 86_400}
  ]

  @expiries [{"Until removed", ""}, {"7 days", "7"}, {"30 days", "30"}, {"90 days", "90"}]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Inbox",
       can_change?: Findings.can_change_workflow?(scope),
       assignees: Findings.assignable_users(scope),
       snoozes: @snoozes,
       expiries: @expiries,
       reload_timer: nil,
       selected: nil,
       history: [],
       exception_form: nil,
       can_decide?: Requests.can_decide?(scope),
       selected_request: nil,
       similar: [],
       request_current: nil,
       decision_form: decision_form()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = parse(params)

    # A different finding starts with a blank exception form.
    socket =
      if socket.assigns[:query] && socket.assigns.query.finding == query.finding,
        do: socket,
        else: assign(socket, :exception_form, nil)

    {:noreply,
     socket
     |> assign(:query, query)
     |> load_findings()
     |> load_selected()
     |> load_requests()
     |> load_selected_request()}
  end

  @impl true
  def handle_event("assign", %{"assignee" => assignee}, socket) do
    assignee = if assignee == "", do: nil, else: assignee

    socket
    |> run(&Findings.assign(&1, &2, assignee), assigned_message(socket, assignee))
    |> reply()
  end

  def handle_event("assign_me", _params, socket) do
    socket
    |> run(&Findings.assign(&1, &2, &1.user.id), "Assigned to you")
    |> reply()
  end

  def handle_event("snooze", %{"for" => "wake"}, socket) do
    socket |> run(&Findings.snooze(&1, &2, nil), "Back in the queue") |> reply()
  end

  def handle_event("snooze", %{"for" => key}, socket) do
    case List.keyfind(@snoozes, key, 0) do
      {_key, label, seconds} ->
        until = DateTime.add(DateTime.utc_now(), seconds)
        socket |> run(&Findings.snooze(&1, &2, until), "Snoozed for #{label}") |> reply()

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_exception", %{"exception" => params}, socket) do
    form =
      socket.assigns.selected
      |> Findings.change_exception(exception_attrs(params))
      |> Map.put(:action, :validate)
      |> to_form(as: :exception)

    {:noreply, assign(socket, :exception_form, form)}
  end

  def handle_event("accept_exception", %{"exception" => params}, socket) do
    attrs = exception_attrs(params)

    socket
    |> run(&Findings.accept_exception(&1, &2, attrs), "Accepted as an exception")
    |> reply()
  end

  def handle_event("remove_exception", _params, socket) do
    socket
    |> run(&Findings.remove_exception/2, "Exception removed")
    |> reply()
  end

  def handle_event("decide", %{"decision" => decision} = params, socket)
      when decision in ~w(approve approve_all reject) do
    %{selected_request: request, similar: similar, current_scope: scope} = socket.assigns
    note = get_in(params, ["decision_form", "note"])

    result =
      case {decision, request} do
        {_decision, nil} -> {:error, :not_found}
        {"approve", request} -> Requests.approve(scope, request, note)
        {"approve_all", request} -> Requests.approve(scope, [request | similar], note)
        {"reject", request} -> Requests.reject(scope, request, note)
      end

    {:noreply, socket |> decision_flash(result) |> after_decision()}
  end

  def handle_event("withdraw_request", _params, socket) do
    %{selected_request: request, current_scope: scope} = socket.assigns
    result = if request, do: Requests.withdraw(scope, request), else: {:error, :not_found}
    {:noreply, socket |> decision_flash(result) |> after_decision()}
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
    {:noreply,
     socket
     |> assign(:reload_timer, nil)
     |> load_findings()
     |> load_selected()
     |> load_requests()
     |> load_selected_request()}
  end

  # Runs a workflow change on the open finding. The context re-reads the
  # finding in the caller's organization, so the id from the URL is not
  # trusted.
  defp run(%{assigns: %{selected: nil}} = socket, _change, _message), do: socket

  defp run(socket, change, message) do
    case change.(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, _workflow} ->
        socket
        |> put_flash(:info, message)
        |> assign(:exception_form, nil)
        |> load_findings()
        |> load_selected()

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :exception_form, to_form(changeset, as: :exception))

      {:error, :forbidden} ->
        put_flash(socket, :error, "Changing a finding requires the member role or higher")

      {:error, :resolved} ->
        socket
        |> put_flash(:error, "This finding was resolved; nothing to set aside")
        |> load_selected()

      {:error, :invalid_assignee} ->
        put_flash(socket, :error, "Choose someone who can work on findings")

      {:error, :not_found} ->
        push_patch(socket, to: inbox_path(socket.assigns.query, finding: nil))
    end
  end

  defp reply(socket), do: {:noreply, socket}

  defp decision_flash(socket, {:ok, 1}), do: put_flash(socket, :info, "Request approved")

  defp decision_flash(socket, {:ok, count}) when is_integer(count),
    do: put_flash(socket, :info, "#{count} requests approved")

  defp decision_flash(socket, {:ok, %Request{status: status}}),
    do: put_flash(socket, :info, "Request #{status}")

  defp decision_flash(socket, {:error, :forbidden}),
    do: put_flash(socket, :error, "Only owners and admins decide requests")

  defp decision_flash(socket, {:error, reason}) when reason in [:closed, :not_found],
    do: put_flash(socket, :error, "That request is no longer open")

  defp decision_flash(socket, {:error, _reason}),
    do:
      put_flash(
        socket,
        :error,
        "The change could not be applied; review the resource and try again"
      )

  defp after_decision(socket) do
    socket
    |> assign(:decision_form, decision_form())
    |> load_findings()
    |> load_requests()
    |> load_selected_request()
  end

  defp decision_form, do: to_form(%{"note" => ""}, as: :decision_form)

  defp assigned_message(_socket, nil), do: "Unassigned"

  defp assigned_message(socket, user_id) do
    case Enum.find(socket.assigns.assignees, &(&1.id == user_id)) do
      nil -> "Assigned"
      user -> "Assigned to #{user.email}"
    end
  end

  defp exception_attrs(params) do
    expires_at =
      case Integer.parse(Map.get(params, "expires", "")) do
        {days, ""} when days > 0 -> DateTime.add(DateTime.utc_now(), days * 86_400)
        _never -> nil
      end

    %{
      "exception_reason" => Map.get(params, "exception_reason", ""),
      "exception_expires_at" => expires_at
    }
  end

  ## Loading

  # The Requests tab lists requests instead; findings still feed the counts.
  defp load_findings(%{assigns: %{query: %{group: "requests"}}} = socket) do
    %{query: query, current_scope: scope} = socket.assigns

    socket
    |> assign(total: 0, counts: Findings.count_by_group(scope, list_options(query, scope)))
    |> stream(:findings, [], reset: true)
  end

  defp load_findings(socket) do
    %{query: query, current_scope: scope} = socket.assigns
    opts = list_options(query, scope)
    {findings, total} = Findings.list_findings(scope, opts)
    counts = Findings.count_by_group(scope, opts)

    socket
    |> assign(
      total: total,
      counts: counts,
      has_next_page?: query.page * Findings.per_page() < total
    )
    |> stream(:findings, with_group_headers(findings, query, counts), reset: true)
  end

  defp load_selected(%{assigns: %{query: %{finding: nil}}} = socket),
    do: assign(socket, selected: nil, history: [], exception_form: nil)

  defp load_selected(socket) do
    %{query: %{finding: {domain, id}}, current_scope: scope} = socket.assigns

    case Findings.get_finding(scope, domain, id) do
      nil ->
        assign(socket, selected: nil, history: [], exception_form: nil)

      finding ->
        assign(socket,
          selected: finding,
          history: Findings.list_history(scope, finding),
          exception_form: socket.assigns.exception_form || exception_form(finding)
        )
    end
  end

  defp load_requests(socket) do
    %{query: query, current_scope: scope} = socket.assigns
    socket = assign(socket, :open_request_count, Requests.count_open(scope))

    cond do
      query.group == "requests" ->
        {requests, total} = Requests.list_requests(scope, status: query.status, page: query.page)

        socket
        |> assign(
          request_total: total,
          request_preview?: false,
          has_next_page?: query.page * Requests.per_page() < total
        )
        |> stream(:requests, requests, reset: true)

      # The All view leads with a few open requests, the RFD's first group.
      query.group == nil and query.state == "open" and not scoped?(query) ->
        {requests, _total} = Requests.list_requests(scope)
        preview = Enum.take(requests, 5)

        socket
        |> assign(request_total: 0, request_preview?: preview != [])
        |> stream(:requests, preview, reset: true)

      true ->
        socket
        |> assign(request_total: 0, request_preview?: false)
        |> stream(:requests, [], reset: true)
    end
  end

  defp load_selected_request(%{assigns: %{query: %{request: nil}}} = socket),
    do: assign(socket, selected_request: nil, similar: [], request_current: nil)

  defp load_selected_request(socket) do
    %{query: %{request: id}, current_scope: scope} = socket.assigns

    case Requests.get_request(scope, id) do
      nil ->
        assign(socket, selected_request: nil, similar: [], request_current: nil)

      request ->
        similar =
          if request.status == "open", do: Requests.similar_requests(scope, request), else: []

        assign(socket,
          selected_request: request,
          similar: similar,
          request_current: Requests.current_value(scope, request)
        )
    end
  end

  defp exception_form(finding),
    do: finding |> Findings.change_exception() |> to_form(as: :exception)

  # Group headers are stream items too, so one page can show "Drift" and
  # "Health" sections. Counts cover the whole filtered queue.
  defp with_group_headers(findings, %{group: nil}, counts) do
    findings
    |> Enum.chunk_by(& &1.group)
    |> Enum.flat_map(fn [%{group: group} | _rest] = rows ->
      [%{id: "group-#{group}", header: %{label: group_label(group), count: counts[group]}} | rows]
    end)
  end

  defp with_group_headers(findings, _query, _counts), do: findings

  ## URL state

  defp parse(params) do
    %{
      group: one_of(params["group"], ["requests" | Findings.groups()]),
      status: one_of(params["status"], Request.statuses()) || "open",
      request: uuid(params["request"]),
      state: one_of(params["state"], Findings.states()) || "open",
      assignee: assignee_param(params["assignee"]),
      domain: one_of(params["domain"], Renga.Findings.Workflow.domains()),
      kind: blank_to_nil(params["kind"]),
      resource: uuid(params["resource"]),
      interface: uuid(params["interface_id"]),
      page: page(params["page"]),
      finding: finding_param(params["finding"])
    }
  end

  defp list_options(query, scope) do
    [
      state: query.state,
      group: query.group,
      assignee: assignee_option(query.assignee, scope),
      domain: query.domain,
      kind: query.kind,
      resource_id: query.resource,
      interface_id: query.interface,
      page: query.page
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp assignee_option("me", scope), do: scope.user.id
  defp assignee_option("unassigned", _scope), do: :unassigned
  defp assignee_option(_all, _scope), do: nil

  defp inbox_path(query, changes) do
    query = Enum.into(changes, query)

    params =
      [
        group: query.group,
        state: if(query.state != "open", do: query.state),
        assignee: query.assignee,
        domain: query.domain,
        kind: query.kind,
        resource: query.resource,
        interface_id: query.interface,
        status: if(query.status != "open", do: query.status),
        page: if(query.page > 1, do: query.page),
        finding: finding_value(query.finding),
        request: query.request
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if params == [], do: ~p"/inbox", else: ~p"/inbox?#{params}"
  end

  defp one_of(value, allowed), do: if(value in allowed, do: value)
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp assignee_param(value) when value in ["me", "unassigned"], do: value
  defp assignee_param(_value), do: nil

  defp uuid(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp page(value) do
    case Integer.parse(value || "") do
      {page, ""} when page > 1 -> page
      _first -> 1
    end
  end

  defp finding_param(value) when is_binary(value) do
    with [domain, id] <- String.split(value, ":", parts: 2),
         true <- domain in Renga.Findings.Workflow.domains(),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {domain, id}
    else
      _invalid -> nil
    end
  end

  defp finding_param(_value), do: nil

  defp finding_value(nil), do: nil
  defp finding_value({domain, id}), do: "#{domain}:#{id}"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:inbox}
    >
      <section id="inbox" class="space-y-4">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div class="flex items-baseline gap-2.5">
            <h1 class="text-xl font-semibold tracking-tight text-fg">Inbox</h1>
            <span id="inbox-count" class="font-mono text-xs tabular-nums text-fg-muted">
              {if(@query.group == "requests", do: @request_total, else: @total)}
            </span>
          </div>
        </header>

        <nav
          id="inbox-groups"
          class="-mb-px flex gap-1 overflow-x-auto border-b border-edge"
          aria-label="Queue groups"
        >
          <.group_tab
            id="inbox-group-requests"
            query={@query}
            group="requests"
            label="Requests"
            count={@open_request_count}
          />
          <.group_tab
            id="inbox-group-all"
            query={@query}
            label="All"
            count={@counts["drift"] + @counts["health"]}
          />
          <.group_tab
            id="inbox-group-drift"
            query={@query}
            group="drift"
            label="Drift"
            count={@counts["drift"]}
          />
          <.group_tab
            id="inbox-group-health"
            query={@query}
            group="health"
            label="Health"
            count={@counts["health"]}
          />
        </nav>

        <.requests_view :if={@query.group == "requests"} {assigns} />

        <section
          :if={@request_preview?}
          id="inbox-requests-preview"
          aria-labelledby="inbox-requests-title"
          class="space-y-2"
        >
          <div class="flex items-baseline justify-between">
            <h2 id="inbox-requests-title" class="text-sm font-semibold text-fg">
              Requests <span class="ml-1 font-mono text-xs text-fg-muted">{@open_request_count}</span>
            </h2>
            <.link
              id="inbox-requests-all"
              patch={inbox_path(@query, group: "requests", page: 1, finding: nil, request: nil)}
              class="text-xs text-link hover:underline"
            >
              See all requests
            </.link>
          </div>
          <.request_table
            id="requests"
            requests={@streams.requests}
            row_click={
              fn {_id, request} -> JS.patch(inbox_path(@query, request: request.id, finding: nil)) end
            }
            selected_id={@selected_request && @selected_request.id}
            empty="No open requests."
          />
        </section>

        <div :if={@query.group != "requests"} class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <.segmented id="inbox-states" label="State">
            <:option
              :for={{value, label} <- state_options()}
              patch={inbox_path(@query, state: value, page: 1, finding: nil)}
              active={@query.state == value}
              id={"inbox-state-#{value}"}
            >
              {label}
            </:option>
          </.segmented>
          <.segmented id="inbox-assignees" label="Assignee">
            <:option
              :for={{value, label} <- assignee_options()}
              patch={inbox_path(@query, assignee: value, page: 1, finding: nil)}
              active={@query.assignee == value}
              id={"inbox-assignee-#{value || "all"}"}
            >
              {label}
            </:option>
          </.segmented>
          <.link
            :if={scoped?(@query)}
            id="inbox-clear-scope"
            patch={inbox_path(@query, domain: nil, kind: nil, resource: nil, interface: nil, page: 1)}
            class="inline-flex min-h-tap items-center gap-1 rounded-full border border-edge px-2.5 text-xs text-fg-muted hover:text-fg"
          >
            {scope_label(@query)} <.icon name="hero-x-mark-mini" class="size-3.5" />
            <span class="sr-only">Clear</span>
          </.link>
        </div>

        <.table
          :if={@query.group != "requests"}
          id="findings"
          rows={@streams.findings}
          row_item={fn {_id, item} -> item end}
          row_id={fn {id, _item} -> id end}
          row_group={fn {_id, item} -> Map.get(item, :header) end}
          row_click={
            fn {_id, finding} ->
              JS.patch(inbox_path(@query, finding: {finding.domain, finding.id}))
            end
          }
          row_selected={fn {_id, finding} -> selected?(@selected, finding) end}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={finding} label="Finding" class="min-w-0 max-w-[28rem] py-2">
            <.link
              id={"finding-link-#{finding.domain}-#{finding.id}"}
              patch={inbox_path(@query, finding: {finding.domain, finding.id})}
              class="block min-w-0 rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
              data-finding-kind={finding.kind}
            >
              <span class="block truncate font-medium text-fg">{kind_label(finding.kind)}</span>
              <span class="block truncate text-xs text-fg-muted">{finding.message}</span>
              <%!-- Phones drop the Resource and Seen columns; the row keeps both here. --%>
              <span class="block truncate text-xs text-fg-subtle sm:hidden">
                {resource_name(finding.resource)}<span :if={finding.interface_name}> · {finding.interface_name}</span> · {Format.age(
                  finding.last_observed_at
                )}
              </span>
            </.link>
          </:col>
          <:col :let={finding} label="Resource" class="hidden max-w-48 truncate sm:table-cell">
            <span class="text-fg">{resource_name(finding.resource)}</span>
            <span :if={finding.interface_name} class="ml-1 font-mono text-xs text-fg-muted">
              {finding.interface_name}
            </span>
          </:col>
          <:col
            :let={finding}
            label="Assignee"
            class="hidden max-w-40 truncate text-fg-muted sm:table-cell"
          >
            <span :if={assignee(finding)} data-assignee>{assignee(finding).email}</span>
            <span :if={!assignee(finding)} class="text-fg-subtle">Unassigned</span>
          </:col>
          <:col
            :let={finding}
            label="Seen"
            class="hidden whitespace-nowrap text-right font-mono text-xs text-fg-muted sm:table-cell"
          >
            <.state_badge finding={finding} />
            <time
              datetime={DateTime.to_iso8601(finding.last_observed_at)}
              title={Format.datetime(finding.last_observed_at)}
            >
              {Format.age(finding.last_observed_at)}
            </time>
          </:col>
          <:empty>
            {empty_message(@query)}
          </:empty>
        </.table>

        <nav
          :if={@query.group != "requests" and (@query.page > 1 or @has_next_page?)}
          id="inbox-pagination"
          class="flex items-center justify-between text-sm"
          aria-label="Inbox pages"
        >
          <.link
            :if={@query.page > 1}
            id="inbox-previous"
            patch={inbox_path(@query, page: @query.page - 1, finding: nil)}
            class="text-link hover:underline"
          >
            Previous
          </.link>
          <span :if={@query.page == 1} />
          <.link
            :if={@has_next_page?}
            id="inbox-next"
            patch={inbox_path(@query, page: @query.page + 1, finding: nil)}
            class="text-link hover:underline"
          >
            Next
          </.link>
        </nav>
      </section>

      <.finding_panel
        :if={@selected}
        finding={@selected}
        history={@history}
        query={@query}
        can_change?={@can_change?}
        assignees={@assignees}
        snoozes={@snoozes}
        expiries={@expiries}
        exception_form={@exception_form}
      />

      <.request_panel
        :if={@selected_request}
        request={@selected_request}
        current_value={@request_current}
        similar={@similar}
        can_decide?={@can_decide?}
        current_user_id={@current_scope.user.id}
        decision_form={@decision_form}
        on_cancel={JS.patch(inbox_path(@query, request: nil))}
      />
    </Layouts.app>
    """
  end

  defp requests_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <.segmented id="inbox-request-statuses" label="Request status">
        <:option
          :for={{value, label} <- request_status_options()}
          patch={inbox_path(@query, status: value, page: 1, request: nil)}
          active={@query.status == value}
          id={"inbox-status-#{value}"}
        >
          {label}
        </:option>
      </.segmented>

      <.request_table
        id="requests"
        requests={@streams.requests}
        row_click={fn {_id, request} -> JS.patch(inbox_path(@query, request: request.id)) end}
        selected_id={@selected_request && @selected_request.id}
        empty={request_empty(@query.status)}
      />

      <nav
        :if={@query.page > 1 or @has_next_page?}
        id="inbox-request-pagination"
        class="flex items-center justify-between text-sm"
        aria-label="Request pages"
      >
        <.link
          :if={@query.page > 1}
          patch={inbox_path(@query, page: @query.page - 1, request: nil)}
          class="text-link hover:underline"
        >
          Previous
        </.link>
        <span :if={@query.page == 1} />
        <.link
          :if={@has_next_page?}
          patch={inbox_path(@query, page: @query.page + 1, request: nil)}
          class="text-link hover:underline"
        >
          Next
        </.link>
      </nav>
    </div>
    """
  end

  defp request_status_options,
    do: [
      {"open", "Open"},
      {"approved", "Approved"},
      {"rejected", "Rejected"},
      {"withdrawn", "Withdrawn"}
    ]

  defp request_empty("open"),
    do: "No open requests. Members request changes they cannot make themselves."

  defp request_empty(status), do: "No #{status} requests."

  attr :id, :string, required: true
  attr :query, :map, required: true
  attr :group, :string, default: nil
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp group_tab(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={inbox_path(@query, group: @group, page: 1, finding: nil, request: nil)}
      aria-current={@query.group == @group && "page"}
      class={[
        "inline-flex min-h-tap shrink-0 items-center gap-1.5 border-b-2 px-3 py-2 text-sm transition-colors",
        @query.group == @group && "border-accent font-medium text-fg",
        @query.group != @group && "border-transparent text-fg-muted hover:text-fg"
      ]}
    >
      {@label}
      <span class="font-mono text-xs tabular-nums text-fg-muted">{@count}</span>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :option, required: true do
    attr :patch, :string, required: true
    attr :active, :boolean, required: true
    attr :id, :string, required: true
  end

  defp segmented(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label={@label}
      class="inline-flex rounded-md border border-edge bg-surface p-0.5"
    >
      <.link
        :for={option <- @option}
        id={option.id}
        patch={option.patch}
        aria-current={option.active && "true"}
        class={[
          "inline-flex min-h-tap items-center rounded px-2.5 text-xs transition-colors sm:min-h-7",
          option.active && "bg-sunken font-medium text-fg",
          !option.active && "text-fg-muted hover:text-fg"
        ]}
      >
        {render_slot(option)}
      </.link>
    </div>
    """
  end

  attr :finding, :map, required: true

  defp state_badge(assigns) do
    ~H"""
    <span
      :if={@finding.state != :open}
      data-state={@finding.state}
      class="mr-2 rounded-sm bg-sunken px-1.5 py-0.5 font-sans text-[11px] text-fg-muted"
    >
      {state_label(@finding)}
    </span>
    """
  end

  attr :finding, :map, required: true
  attr :history, :list, required: true
  attr :query, :map, required: true
  attr :can_change?, :boolean, required: true
  attr :assignees, :list, required: true
  attr :snoozes, :list, required: true
  attr :expiries, :list, required: true
  attr :exception_form, :any, required: true

  defp finding_panel(assigns) do
    ~H"""
    <.side_panel
      id="finding-panel"
      title={kind_label(@finding.kind)}
      description={@finding.message}
      show
      on_cancel={JS.patch(inbox_path(@query, finding: nil))}
    >
      <div class="space-y-6">
        <.properties id="finding-properties" title="Finding">
          <:item label="Resource">
            <.link navigate={resource_path(@finding)} class="text-link hover:underline">
              {resource_name(@finding.resource)}
            </.link>
          </:item>
          <:item :if={@finding.interface_name} label="Interface">
            <span class="font-mono">{@finding.interface_name}</span>
          </:item>
          <:item label="Area">{domain_label(@finding.domain)}</:item>
          <:item label="State"><span id="finding-state">{state_label(@finding)}</span></:item>
          <:item label="Opened">{Format.datetime(@finding.opened_at)}</:item>
          <:item label="Last seen">{Format.datetime(@finding.last_observed_at)}</:item>
          <:item :if={@finding.resolved_at} label="Resolved">
            {Format.datetime(@finding.resolved_at)}
          </:item>
        </.properties>

        <div
          :if={@finding.state == :excepted}
          id="finding-exception"
          class="space-y-1 rounded-md border border-edge bg-sunken px-3 py-2 text-sm"
        >
          <p class="font-medium text-fg">Accepted as an exception</p>
          <p class="text-fg-muted">“{@finding.workflow.exception_reason}”</p>
          <p class="text-xs text-fg-muted">
            {person(@finding.workflow.exception_by_user)} · {Format.datetime(
              @finding.workflow.exception_at
            )}
            <span :if={@finding.workflow.exception_expires_at}>
              · until {Format.datetime(@finding.workflow.exception_expires_at)}
            </span>
          </p>
        </div>

        <p
          :if={@finding.state == :snoozed}
          id="finding-snoozed"
          class="rounded-md border border-edge bg-sunken px-3 py-2 text-sm text-fg-muted"
        >
          Snoozed until {Format.datetime(@finding.workflow.snoozed_until)}
        </p>

        <section
          :if={@can_change? and @finding.status == "open"}
          id="finding-actions"
          class="space-y-5"
        >
          <form id="finding-assign-form" phx-change="assign" class="space-y-1.5">
            <label for="finding-assignee" class="text-xs font-medium text-fg-muted">Assignee</label>
            <div class="flex gap-2">
              <select
                id="finding-assignee"
                name="assignee"
                class="h-control min-h-tap min-w-0 flex-1 rounded-md border border-edge bg-surface px-2 text-sm text-fg focus:border-accent focus:outline-none focus:ring-2 focus:ring-ring"
              >
                <option value="">Unassigned</option>
                <option
                  :for={user <- @assignees}
                  value={user.id}
                  selected={assignee(@finding) && assignee(@finding).id == user.id}
                >
                  {user.email}
                </option>
              </select>
              <.button id="finding-assign-me" type="button" phx-click="assign_me">
                Assign to me
              </.button>
            </div>
          </form>

          <div class="space-y-1.5">
            <p class="text-xs font-medium text-fg-muted">Snooze</p>
            <div id="finding-snooze" class="flex flex-wrap gap-2">
              <.button
                :for={{key, label, _seconds} <- @snoozes}
                id={"finding-snooze-#{key}"}
                type="button"
                phx-click={JS.push("snooze", value: %{for: key})}
              >
                {label}
              </.button>
              <.button
                :if={@finding.state == :snoozed}
                id="finding-wake"
                type="button"
                phx-click={JS.push("snooze", value: %{for: "wake"})}
              >
                Wake now
              </.button>
            </div>
          </div>

          <.form
            :if={@finding.state != :excepted}
            for={@exception_form}
            id="finding-exception-form"
            phx-change="validate_exception"
            phx-submit="accept_exception"
            class="space-y-1.5"
          >
            <p class="text-xs font-medium text-fg-muted">Accept as an exception</p>
            <.input
              field={@exception_form[:exception_reason]}
              type="textarea"
              label="Why is this acceptable?"
              rows="2"
            />
            <.input
              name="exception[expires]"
              id="finding-exception-expires"
              type="select"
              label="Lasts"
              value=""
              options={@expiries}
            />
            <div class="flex justify-end">
              <.button id="finding-exception-save" variant="primary" phx-disable-with="Saving…">
                Accept as exception
              </.button>
            </div>
          </.form>

          <.button
            :if={@finding.state == :excepted}
            id="finding-exception-remove"
            type="button"
            phx-click="remove_exception"
          >
            Remove exception
          </.button>
        </section>

        <p
          :if={!@can_change? and @finding.status == "open"}
          id="finding-actions-unavailable"
          class="text-sm text-fg-muted"
        >
          Assigning, snoozing, and accepting exceptions require the member role or higher.
        </p>

        <p :if={@finding.status != "open"} class="text-sm text-fg-muted">
          Reconciliation resolved this finding when it stopped observing the condition.
        </p>

        <section :if={@history != []} aria-labelledby="finding-history-title">
          <h3 id="finding-history-title" class="mb-2 text-xs font-medium text-fg-muted">History</h3>
          <ol id="finding-history" class="space-y-2">
            <li :for={event <- @history} id={"finding-history-#{event.id}"} class="text-sm">
              <p class="text-fg">{history_label(event)}</p>
              <p class="text-xs text-fg-muted">
                {person(event.actor_user)} · {Format.datetime(event.occurred_at)}
              </p>
            </li>
          </ol>
        </section>
      </div>
    </.side_panel>
    """
  end

  ## Labels

  defp state_options,
    do: [
      {"open", "Open"},
      {"snoozed", "Snoozed"},
      {"excepted", "Exceptions"},
      {"resolved", "Resolved"}
    ]

  defp assignee_options, do: [{nil, "Anyone"}, {"me", "Mine"}, {"unassigned", "Unassigned"}]

  defp group_label("drift"), do: "Drift"
  defp group_label("health"), do: "Health"

  @acronyms %{"vlan" => "VLAN", "vid" => "VID", "nvme" => "NVMe", "psu" => "PSU"}

  defp kind_label(kind) do
    kind
    |> Format.humanize()
    |> String.capitalize()
    |> String.split(" ")
    |> Enum.map_join(" ", &Map.get(@acronyms, &1, &1))
  end

  defp domain_label("component"), do: "Hardware components"
  defp domain_label("hardware_match"), do: "Catalog match"
  defp domain_label("placement"), do: "Placement"
  defp domain_label("topology"), do: "Network"

  defp state_label(%{state: :open}), do: "Open"
  defp state_label(%{state: :snoozed}), do: "Snoozed"
  defp state_label(%{state: :excepted}), do: "Exception"
  defp state_label(%{state: :resolved}), do: "Resolved"

  defp history_label(%{kind: "finding_assigned", new_value: nil}), do: "Unassigned"

  defp history_label(%{kind: "finding_assigned", new_value: %{"assignee" => email}}),
    do: "Assigned to #{email}"

  defp history_label(%{kind: "finding_snoozed", new_value: nil}), do: "Woken"

  defp history_label(%{kind: "finding_snoozed", new_value: %{"snoozed_until" => until}}),
    do: "Snoozed until #{iso_label(until)}"

  defp history_label(%{kind: "finding_exception", new_value: %{"reason" => reason}}),
    do: "Accepted as an exception: “#{reason}”"

  defp history_label(%{kind: "finding_exception_removed"}), do: "Exception removed"
  defp history_label(%{kind: kind}), do: Format.humanize(kind)

  defp iso_label(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> Format.datetime(datetime)
      _invalid -> iso
    end
  end

  defp person(%{email: email}), do: email
  defp person(_missing), do: "Someone no longer in the organization"

  defp assignee(%{workflow: %{assignee_user: %{} = user}}), do: user
  defp assignee(_finding), do: nil

  defp resource_name(resource), do: resource.display_name || resource.name

  # Each finding opens the resource tab where its evidence lives.
  defp resource_path(%{domain: domain, resource: resource})
       when domain in ["component", "hardware_match"],
       do: ~p"/inventory/#{resource}/hardware"

  defp resource_path(%{domain: "topology", resource: resource}),
    do: ~p"/inventory/#{resource}/network"

  defp resource_path(%{resource: resource}), do: ~p"/inventory/#{resource}"

  defp selected?(%{domain: domain, id: id}, %{domain: domain, id: id}), do: true
  defp selected?(_selected, _finding), do: false

  defp scoped?(query), do: Enum.any?([query.domain, query.kind, query.resource, query.interface])

  defp scope_label(%{interface: interface}) when not is_nil(interface), do: "One interface"
  defp scope_label(%{resource: resource}) when not is_nil(resource), do: "One resource"
  defp scope_label(%{kind: kind}) when not is_nil(kind), do: kind_label(kind)
  defp scope_label(%{domain: domain}), do: domain_label(domain)

  defp empty_message(%{state: "open", assignee: nil}),
    do: "Nothing needs attention. Findings appear here when reconciliation observes a problem."

  defp empty_message(%{state: "open"}), do: "No open findings match."
  defp empty_message(%{state: "snoozed"}), do: "No snoozed findings."
  defp empty_message(%{state: "excepted"}), do: "No findings are accepted as exceptions."
  defp empty_message(%{state: "resolved"}), do: "No resolved findings yet."
end
