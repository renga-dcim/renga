defmodule RengaWeb.JobsLive do
  @moduledoc """
  The Jobs tab of Activity (RFD 9, "Interface"): work requested of agents,
  newest first, filtered by where it stands. Opening a job shows its detail
  and history in a side panel, where owners and admins can cancel an open
  job or record what happened to one that needs review.

  The list follows jobs as they move: it re-reads when the organization's
  jobs change.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.JobComponents

  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Changes
  alias Renga.Jobs.Job
  alias RengaWeb.Format

  @groups [
    {nil, "All"},
    {"open", "Open"},
    {"needs_review", "Needs review"},
    {"finished", "Finished"}
  ]
  @reload_after_ms 300
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: "Jobs",
       groups: @groups,
       can_manage?: Inventory.organization_manager?(scope),
       retention_days: Jobs.get_settings(scope.organization).retention_days,
       reload_timer: nil,
       job: nil,
       events: [],
       actor_names: %{},
       resolve_form: resolve_form()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    group = if params["state"] in Map.keys(Jobs.state_groups()), do: params["state"]
    reset? = !Map.has_key?(socket.assigns, :group) or socket.assigns.group != group
    limit = if reset?, do: @page_size, else: socket.assigns.loaded_limit

    {:noreply,
     socket
     |> assign(:group, group)
     |> load_jobs(limit)
     |> load_job(params["id"])}
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    opts = job_filters(socket) ++ [before: socket.assigns.oldest, limit: @page_size + 1]
    jobs = Jobs.list_jobs(socket.assigns.current_scope, opts)
    {page, more?} = page(jobs, @page_size)

    {:noreply,
     socket
     |> assign(
       oldest: List.last(page) || socket.assigns.oldest,
       more?: more?,
       loaded_limit: socket.assigns.loaded_limit + length(page)
     )
     |> stream(:jobs, page)}
  end

  @impl true
  def handle_event("cancel", %{"id" => id}, socket) do
    case Jobs.cancel_job(socket.assigns.current_scope, id) do
      {:ok, %Job{state: "cancelled"}} ->
        {:noreply, socket |> put_flash(:info, "Job cancelled") |> refresh()}

      {:ok, %Job{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancel requested; the agent stops at its next report")
         |> refresh()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can cancel jobs")}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "This job already ended") |> refresh()}
    end
  end

  def handle_event("resolve", %{"resolve" => %{"outcome" => outcome} = params}, socket)
      when outcome in ~w(succeeded failed) do
    %{current_scope: scope, job: job} = socket.assigns

    case Jobs.resolve_job(scope, job.id, outcome, params["note"]) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Outcome recorded")
         |> assign(:resolve_form, resolve_form())
         |> refresh()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can record an outcome")}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "This job no longer needs review") |> refresh()}
    end
  end

  def handle_event("resolve", _params, socket) do
    form = resolve_form(%{}, outcome: {"Choose what happened", []})
    {:noreply, assign(socket, :resolve_form, form)}
  end

  @impl true
  def handle_info({:jobs_changed, _organization_id}, %{assigns: %{reload_timer: nil}} = socket) do
    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info({:jobs_changed, _organization_id}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> assign(:reload_timer, nil) |> refresh()}

  defp refresh(socket),
    do:
      socket
      |> load_jobs(socket.assigns.loaded_limit)
      |> load_job(socket.assigns.job && socket.assigns.job.id)

  defp load_jobs(socket, limit) do
    scope = socket.assigns.current_scope
    jobs = Jobs.list_jobs(scope, job_filters(socket) ++ [limit: limit + 1])
    {jobs, more?} = page(jobs, limit)

    socket
    |> assign(:counts, Jobs.count_jobs_by_group(scope))
    |> assign(oldest: List.last(jobs), more?: more?, loaded_limit: limit)
    |> stream(:jobs, jobs, reset: true)
  end

  defp job_filters(%{assigns: %{group: nil}}), do: []
  defp job_filters(%{assigns: %{group: group}}), do: [group: group]

  defp page(jobs, limit), do: {Enum.take(jobs, limit), length(jobs) > limit}

  defp load_job(socket, nil), do: assign(socket, job: nil, events: [], actor_names: %{})

  defp load_job(socket, id) do
    scope = socket.assigns.current_scope

    case Jobs.get_job(scope, id, preload: [:resource, :agent, :requested_by_user]) do
      nil ->
        socket
        |> put_flash(
          :error,
          "That job no longer exists; finished jobs are kept for a limited time"
        )
        |> push_patch(to: list_path(socket.assigns.group))

      job ->
        events = Jobs.list_events(scope, job)

        assign(socket,
          job: job,
          events: events,
          actor_names: Jobs.event_actor_names(scope, events),
          page_title: Jobs.title(job)
        )
    end
  end

  defp resolve_form(params \\ %{}, errors \\ []) do
    to_form(params, as: :resolve, id: "job-resolve", errors: errors)
  end

  defp list_path(nil), do: ~p"/activity/jobs"
  defp list_path(group), do: ~p"/activity/jobs?#{[state: group]}"

  defp job_path(job, nil), do: ~p"/activity/jobs/#{job}"
  defp job_path(job, group), do: ~p"/activity/jobs/#{job}?#{[state: group]}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:jobs}
    >
      <div id="jobs" class="mx-auto max-w-6xl space-y-5">
        <.header>
          Jobs
          <:subtitle>
            Work requested of agents. Each job runs one capability on one agent and keeps its history for {@retention_days} days.
          </:subtitle>
        </.header>

        <.segmented id="jobs-filter" label="State">
          <:option
            :for={{group, label} <- @groups}
            id={"jobs-filter-#{group || "all"}"}
            patch={list_path(group)}
            active={group == @group}
          >
            {label}
            <span :if={group && group != "finished"} class="ml-1.5 font-mono text-[11px]">
              {@counts[group]}
            </span>
          </:option>
        </.segmented>

        <.table
          id="jobs-list"
          rows={@streams.jobs}
          row_item={fn {_id, job} -> job end}
          row_patch={fn {_id, job} -> job_path(job, @group) end}
          row_selected={fn {_id, job} -> @job && job.id == @job.id end}
          overflow="clip"
        >
          <:col :let={job} label="Job" class="w-44 font-medium">{Jobs.title(job)}</:col>
          <:col :let={job} label="Target">
            <.job_target job={job} />
          </:col>
          <:col :let={job} label="State" class="w-40">
            <.job_state job={job} id={"job-#{job.id}-state"} />
          </:col>
          <:col :let={job} label="Detail" class="text-xs text-fg-muted" hide_below="3xl">
            {detail(job) || "—"}
          </:col>
          <:col :let={job} label="Requested by" class="w-48 text-fg-muted" hide_below="xl">
            {requester(job, @current_scope.user.id)}
          </:col>
          <:col :let={job} label="Requested" class="w-40 text-fg-muted" hide_below="xl">
            <time datetime={DateTime.to_iso8601(job.inserted_at)}>{when_label(job.inserted_at)}</time>
          </:col>
          <:col
            :let={job}
            label="Took"
            class="w-20 text-right font-mono text-xs text-fg-muted"
            hide_below="3xl"
          >
            {took(job) || "—"}
          </:col>
          <:empty>
            {empty_message(@group)}
          </:empty>
        </.table>

        <div :if={@more?} class="flex justify-center">
          <.button id="jobs-load-older" phx-click="load_older">Load older jobs</.button>
        </div>
      </div>

      <.job_panel
        :if={@job}
        job={@job}
        events={@events}
        actor_names={@actor_names}
        viewer_id={@current_scope.user.id}
        can_manage?={@can_manage?}
        resolve_form={@resolve_form}
        close={JS.patch(list_path(@group))}
      />
    </Layouts.app>
    """
  end

  defp empty_message(nil),
    do: "No jobs yet. Request one with Collect now on a resource whose agent accepts it."

  defp empty_message("open"), do: "Nothing is waiting or running."
  defp empty_message("needs_review"), do: "No job needs review."
  defp empty_message("finished"), do: "No finished jobs in the retention period."

  attr :job, Job, required: true

  defp job_target(%{job: %Job{resource: %{} = resource}} = assigns) do
    assigns = assign(assigns, :resource, resource)

    ~H"""
    <span class="flex min-w-0 items-baseline gap-1.5">
      <span class="truncate">{@resource.display_name || @resource.name}</span>
      <span
        :if={@resource.display_name && @resource.display_name != @resource.name}
        class="truncate font-mono text-xs text-fg-muted"
      >
        {@resource.name}
      </span>
    </span>
    """
  end

  defp job_target(assigns) do
    ~H"""
    <span class="truncate">{agent_name(@job.agent)}</span>
    """
  end

  defp agent_name(%{name: name}) when is_binary(name), do: name
  defp agent_name(_agent), do: "Unnamed agent"

  attr :job, Job, required: true
  attr :events, :list, required: true
  attr :actor_names, :map, required: true
  attr :viewer_id, :string, required: true
  attr :can_manage?, :boolean, required: true
  attr :resolve_form, :any, required: true
  attr :close, JS, required: true

  defp job_panel(assigns) do
    ~H"""
    <.side_panel
      id="job-panel"
      title={Jobs.title(@job)}
      show
      on_cancel={@close}
      return_focus={"#jobs-#{@job.id}-link"}
    >
      <div class="space-y-6">
        <p :if={@job.resource} id="job-panel-target" class="-mt-2 text-sm text-fg-muted">
          <.link navigate={~p"/inventory/#{@job.resource}"} class="text-link hover:underline">
            {@job.resource.display_name || @job.resource.name}
          </.link>
          <span class="font-mono text-xs">· on {agent_name(@job.agent)}</span>
        </p>

        <.job_status job={@job} />

        <.form
          :if={@job.state == "uncertain" and @can_manage?}
          for={@resolve_form}
          id="job-resolve-form"
          phx-submit="resolve"
          class="space-y-3"
        >
          <h3 class="text-sm font-semibold text-fg">What happened?</h3>
          <fieldset class="space-y-1.5">
            <legend class="sr-only">Outcome</legend>
            <label
              :for={
                {value, label} <- [
                  {"succeeded", "It took effect"},
                  {"failed", "It didn't take effect"}
                ]
              }
              class="flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md border border-edge bg-surface px-3 text-sm transition-colors hover:bg-sunken has-checked:border-accent has-checked:bg-accent-tint"
            >
              <input
                type="radio"
                name="resolve[outcome]"
                value={value}
                checked={@resolve_form[:outcome].value == value}
                class="accent-[var(--rg-accent)]"
              />
              {label}
            </label>
            <p :for={{_field, {message, _opts}} <- @resolve_form.errors} class="text-xs text-crit">
              {message}
            </p>
          </fieldset>
          <.input field={@resolve_form[:note]} type="textarea" label="Note" rows="3" />
          <p class="text-xs text-fg-muted">
            Recorded as succeeded or failed with your note. To try again, request a new job.
          </p>
        </.form>

        <dl id="job-panel-facts" class="-mx-2">
          <.fact label="Capability">
            <span class="font-mono text-xs">{Job.capability_key(@job)}</span>
          </.fact>
          <.fact label="Agent">{agent_name(@job.agent)}</.fact>
          <.fact label="Requested by">{requester(@job, @viewer_id)}</.fact>
          <.fact :if={@job.state == "queued"} label="Pick-up deadline">
            {Format.datetime(@job.not_after)}
          </.fact>
          <.fact label="Risk">{risk(@job)}</.fact>
          <.fact label="Job ID"><span class="font-mono text-xs text-fg-muted">{@job.id}</span></.fact>
        </dl>

        <section aria-labelledby="job-history-title" class="space-y-3">
          <h3
            id="job-history-title"
            class="text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle"
          >
            History
          </h3>
          <ol id="job-history" class="space-y-3">
            <li
              :for={entry <- history(@events, @job)}
              id={"job-event-#{entry.id}"}
              data-type={entry.type}
              class="relative border-l border-edge pl-4"
            >
              <span class={["absolute -left-1 top-1.5 size-2 rounded-full", entry.mark]} />
              <p class="text-sm text-fg">
                <span class="font-medium">{entry.label}</span>
                <span :if={entry.note} class="text-fg-muted">{entry.note}</span>
              </p>
              <p class="mt-0.5 text-xs text-fg-muted">
                {Calendar.strftime(entry.at, "%Y-%m-%d %H:%M:%S UTC")} · {actor(
                  entry.event,
                  @actor_names
                )}
              </p>
            </li>
          </ol>
        </section>
      </div>
      <:footer>
        <.button
          :if={@can_manage? and Job.open?(@job) and is_nil(@job.cancel_requested_at)}
          id="job-cancel"
          variant="ghost"
          class="text-crit"
          phx-click={JS.push("cancel", value: %{id: @job.id})}
        >
          Cancel job
        </.button>
        <.button id="job-close" type="button" phx-click={@close}>Close</.button>
        <.button
          :if={@job.state == "uncertain" and @can_manage?}
          id="job-resolve"
          variant="primary"
          form="job-resolve-form"
        >
          Record outcome
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="grid min-h-8 grid-cols-[8rem_minmax(0,1fr)] items-center gap-2 px-2 text-sm">
      <dt class="text-fg-muted">{@label}</dt>
      <dd class="min-w-0 truncate">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :job, Job, required: true

  defp job_status(assigns) do
    ~H"""
    <div
      id="job-panel-status"
      data-state={@job.state}
      role={if(@job.state == "uncertain", do: "alert", else: "status")}
      class={[
        "flex items-start gap-2.5 rounded-md px-3 py-2.5",
        @job.state == "uncertain" && "border border-warn-line bg-warn-fill",
        @job.state != "uncertain" && "bg-sunken"
      ]}
    >
      <span class="mt-0.5 grid size-4 shrink-0 place-items-center">
        <.state_mark state={@job.state} class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-medium text-fg">{state_label(@job)}</p>
        <p class="text-xs text-fg-muted">{status_detail(@job)}</p>
      </div>
    </div>
    """
  end

  defp status_detail(%Job{state: "uncertain"}),
    do:
      "The agent started this, then stopped reporting. Renga won't run it again on its own; check the target and record what happened."

  defp status_detail(%Job{state: state} = job) when state in ~w(leased running) do
    attempt = "Attempt #{job.attempts} of #{job.max_attempts}"

    if job.cancel_requested_at,
      do: "#{attempt} · cancel requested; the agent stops at its next report",
      else: "#{attempt} · the agent reports at least once a minute"
  end

  defp status_detail(%Job{} = job) do
    [detail(job), took(job) && "took #{took(job)}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Requested #{Format.datetime(job.inserted_at)}"
      text -> text
    end
  end

  defp risk(%Job{risk_class: risk, retry_class: retry}) do
    retry =
      case retry do
        "imperative" -> "not retried once started"
        _safe -> "safe to retry"
      end

    "#{String.capitalize(risk)} · #{retry}"
  end

  # Agents report progress as a heartbeat while they work, so consecutive
  # progress events collapse into one line rather than filling the history.
  defp history(events, job) do
    events
    |> Enum.chunk_by(&(&1.type == "progress"))
    |> Enum.flat_map(fn
      [%{type: "progress"} | _] = run -> [history_entry(List.last(run), job, length(run))]
      run -> Enum.map(run, &history_entry(&1, job, 1))
    end)
  end

  defp history_entry(event, job, count) do
    {label, note, mark} = describe_event(event, job, count)

    %{
      id: event.id,
      type: event.type,
      label: label,
      note: note,
      mark: mark,
      at: event.inserted_at,
      event: event
    }
  end

  defp describe_event(%{type: "created"}, _job, _count), do: {"Requested", nil, "bg-fg-subtle"}

  defp describe_event(%{type: "leased", attempt: attempt}, _job, _count),
    do: {"Picked up", "attempt #{attempt}", "bg-fg-subtle"}

  defp describe_event(%{type: "started"}, _job, _count), do: {"Started", nil, "bg-fg-subtle"}

  defp describe_event(%{type: "progress", payload: payload}, _job, count) do
    note =
      case payload do
        %{"message" => message} when is_binary(message) -> message
        _heartbeat when count > 1 -> "#{count} reports"
        _heartbeat -> nil
      end

    {"Progress", note, "bg-info"}
  end

  defp describe_event(%{type: "output"}, _job, _count), do: {"Output", nil, "bg-fg-subtle"}

  defp describe_event(%{type: "succeeded"}, job, _count),
    do: {"Succeeded", detail(%{job | state: "succeeded"}), "bg-ok"}

  defp describe_event(%{type: "failed", payload: payload}, _job, _count),
    do: {"Failed", failure(payload["reason"]), "bg-crit"}

  defp describe_event(%{type: "cancel_requested"}, _job, _count),
    do: {"Cancel requested", nil, "bg-fg-subtle"}

  defp describe_event(%{type: "cancelled"}, _job, _count), do: {"Cancelled", nil, "bg-unknown"}

  defp describe_event(%{type: "lease_lost"}, _job, _count),
    do: {"Lost contact", "no report for 60s", "border-[1.5px] border-crit bg-surface"}

  defp describe_event(%{type: "expired", payload: %{"reason" => "lease_lost"}}, _job, _count),
    do: {"Expired", "out of attempts", "border-[1.5px] border-unknown bg-surface"}

  defp describe_event(%{type: "expired"}, _job, _count),
    do:
      {"Expired", "not picked up before the deadline", "border-[1.5px] border-unknown bg-surface"}

  defp describe_event(%{type: "uncertain"}, _job, _count),
    do: {"Marked for review", "not safe to retry", "bg-warn"}

  defp describe_event(%{type: "resolved", payload: payload}, _job, _count) do
    outcome = if payload["outcome"] == "succeeded", do: "took effect", else: "didn't take effect"
    note = if payload["note"], do: "#{outcome}: “#{payload["note"]}”", else: outcome
    {"Resolved", note, if(payload["outcome"] == "succeeded", do: "bg-ok", else: "bg-crit")}
  end

  defp describe_event(%{type: type}, _job, _count),
    do: {String.capitalize(Format.humanize(type)), nil, "bg-fg-subtle"}

  defp actor(%{actor_type: "system"}, _names), do: "Renga"
  defp actor(%{actor_id: id}, names), do: Map.get(names, id, "Unknown")
end
