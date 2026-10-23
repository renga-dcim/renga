defmodule RengaWeb.QueryBatchLive do
  @moduledoc """
  A query fanned out across many hosts (RFD 12, "Results"): one table of what
  every host answered, filling in as agents report, so "which hosts listen
  on port 23" reads as rows with a host column.

  A list result contributes one row per item, prefixed with its host; a
  result without a list contributes one row per host. Below it, every host
  in the batch shows how its run stands, linking to that run on the host's
  Queries tab. A reader without the query's permissions sees the hosts and
  their states, not what they answered.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.JobComponents
  import RengaWeb.QueryComponents

  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Jobs.Query
  alias Renga.Jobs.Query.Schema

  @reload_after_ms 300
  @max_rows 2000

  @impl true
  def mount(%{"batch_id" => batch_id}, _session, socket) do
    if connected?(socket), do: Jobs.Changes.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(batch_id: batch_id, reload_timer: nil)
     |> load_batch()}
  end

  @impl true
  def handle_info({:jobs_changed, _organization_id}, %{assigns: %{reload_timer: nil}} = socket) do
    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info({:jobs_changed, _organization_id}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> assign(:reload_timer, nil) |> load_batch()}

  defp load_batch(socket) do
    scope = socket.assigns.current_scope

    jobs =
      case Ecto.UUID.cast(socket.assigns.batch_id) do
        {:ok, batch_id} ->
          Jobs.list_jobs(scope, batch_id: batch_id, limit: Jobs.max_batch_size())

        :error ->
          []
      end

    with [first | _] <- jobs,
         module when not is_nil(module) <- Query.module_for(Job.capability_key(first)) do
      jobs = Enum.sort_by(jobs, &resource_name/1)

      assign(socket,
        page_title: "#{module.title()} across #{hosts(length(jobs))}",
        module: module,
        first: first,
        jobs: jobs,
        counts: counts(jobs),
        table: result_table(module, jobs)
      )
    else
      _missing -> raise Ecto.NoResultsError, queryable: Job
    end
  end

  defp counts(jobs) do
    Enum.frequencies_by(jobs, fn
      %Job{state: "succeeded"} -> :answered
      %Job{state: state} when state in ~w(queued leased running) -> :waiting
      %Job{} -> :failed
    end)
  end

  # One table for the whole batch: a host column, then the query's list
  # columns (a row per item) or its other fields (a row per host).
  defp result_table(module, jobs) do
    answered = for job <- jobs, parts = result_parts(module, job), do: {job, parts}
    {columns, rows} = table_rows(result_columns(module, answered), answered)

    %{
      columns: columns,
      rows: Enum.take(rows, @max_rows),
      total: length(rows),
      empty_hosts:
        for(
          {job, %{lists: [_ | _] = lists}} <- answered,
          Enum.all?(lists, &(&1.rows == [])),
          do: job
        ),
      truncated: for({job, %{truncated?: true}} <- answered, do: job)
    }
  end

  # Columns come from the schema rather than from what arrived, so the table
  # has its header before any host answers. An osquery SQL result names its
  # own columns, so its table takes every column any host answered with.
  defp result_columns(module, answered) do
    fields = Schema.fields(module.result_schema())
    objects = Enum.find(fields, &match?({_name, {:list, {:object, _}, _opts}, _required?}, &1))
    strings = Enum.find(fields, &match?({_name, {:list, {:list, _, _}, _opts}, _required?}, &1))

    cond do
      objects ->
        {name, {:list, item, _opts}, _required?} = objects
        {:list, name, Schema.fields(item)}

      strings ->
        {name, _type, _required?} = strings
        {:list, name, answered_columns(answered, name)}

      true ->
        {:scalars, Enum.reject(fields, &match?({"truncated", :boolean, _}, &1))}
    end
  end

  defp answered_columns(answered, name) do
    Enum.uniq(
      for {_job, parts} <- answered,
          %{name: ^name, columns: columns} <- parts.lists,
          column <- columns,
          do: column
    )
  end

  defp table_rows({:list, name, columns}, answered) do
    rows =
      for {job, parts} <- answered,
          %{name: ^name, rows: items} <- parts.lists,
          item <- items,
          do: {job, item}

    {columns, rows}
  end

  defp table_rows({:scalars, columns}, answered),
    do: {columns, for({job, parts} <- answered, do: {job, Map.new(parts.scalars)})}

  defp hosts(1), do: "1 host"
  defp hosts(count), do: "#{count} hosts"

  defp resource_name(%Job{resource: %{} = resource}), do: resource.display_name || resource.name
  defp resource_name(%Job{}), do: "A removed resource"

  defp host_names(jobs), do: Enum.map_join(jobs, ", ", &resource_name/1)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :max_rows, @max_rows)

    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:jobs}
    >
      <div id="query-batch" class="mx-auto max-w-6xl space-y-6">
        <.header>
          {@module.title()} across {hosts(length(@jobs))}
          <:subtitle>
            <span :if={asked(@first)}>{asked(@first)} · </span>
            ran by {requester(@first, @current_scope.user.id)} · {when_label(@first.inserted_at)}
          </:subtitle>
        </.header>

        <p id="query-batch-counts" class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
          <span id="query-batch-answered">
            <span class="font-mono tabular-nums">{@counts[:answered] || 0}</span> answered
          </span>
          <span id="query-batch-waiting" class="text-fg-muted">
            <span class="font-mono tabular-nums">{@counts[:waiting] || 0}</span> waiting
          </span>
          <span
            id="query-batch-failed"
            class={if(@counts[:failed], do: "text-crit", else: "text-fg-muted")}
          >
            <span class="font-mono tabular-nums">{@counts[:failed] || 0}</span> didn't answer
          </span>
        </p>

        <p :if={@first.payload_hidden} id="query-batch-hidden" class="text-sm text-fg-muted">
          What the hosts answered needs
          <span class="font-mono text-xs text-fg">
            {Enum.join(Jobs.payload_permissions(@first), " and ")}
          </span>
        </p>

        <section
          :if={!@first.payload_hidden}
          aria-labelledby="query-batch-results-heading"
          class="space-y-2"
        >
          <h2 id="query-batch-results-heading" class="text-sm font-semibold">Results</h2>
          <.table
            id="query-batch-results"
            rows={Enum.with_index(@table.rows)}
            row_id={fn {_row, index} -> "query-batch-row-#{index}" end}
          >
            <:col :let={{{job, _row}, _index}} label="Host" class="font-medium">
              <.link
                :if={job.resource}
                navigate={~p"/inventory/#{job.resource}/queries?#{[run: job.id]}"}
                class="hover:underline"
              >
                {resource_name(job)}
              </.link>
            </:col>
            <:col
              :let={{{_job, row}, _index}}
              :for={{column, _type, _required?} <- @table.columns}
              label={label(column)}
            >
              <span class={value_class(row[column])}>{format_value(column, row[column])}</span>
            </:col>
            <:empty>
              {if @counts[:answered],
                do: "Nothing matched on any host.",
                else: "No host has answered yet."}
            </:empty>
          </.table>
          <p :if={@table.total > @max_rows} id="query-batch-capped" class="text-sm text-fg-muted">
            Showing the first {@max_rows} of {@table.total} rows.
          </p>
          <p :if={@table.empty_hosts != []} id="query-batch-empty" class="text-sm text-fg-muted">
            Nothing matched on {host_names(@table.empty_hosts)}.
          </p>
          <p :if={@table.truncated != []} id="query-batch-truncated" class="text-sm text-warn-text">
            Cut short to fit the result size limit on {host_names(@table.truncated)}.
          </p>
        </section>

        <section aria-labelledby="query-batch-hosts-heading" class="space-y-2">
          <h2 id="query-batch-hosts-heading" class="text-sm font-semibold">Hosts</h2>
          <.table
            id="query-batch-hosts"
            rows={@jobs}
            row_id={&"query-batch-host-#{&1.id}"}
            overflow="clip"
          >
            <:col :let={job} label="Host" class="font-medium">
              <.link
                :if={job.resource}
                navigate={~p"/inventory/#{job.resource}/queries?#{[run: job.id]}"}
                class="hover:underline"
              >
                {resource_name(job)}
              </.link>
              <span :if={!job.resource}>{resource_name(job)}</span>
            </:col>
            <:col :let={job} label="State" class="w-36 @3xl:w-40">
              <.job_state job={job} id={"query-batch-host-#{job.id}-state"} />
            </:col>
            <:col :let={job} label="Detail" class="text-xs text-fg-muted" hide_below="xl">
              {detail(job) || "—"}
            </:col>
          </.table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
