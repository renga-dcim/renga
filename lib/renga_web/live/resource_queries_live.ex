defmodule RengaWeb.ResourceQueriesLive do
  @moduledoc """
  A host's Queries tab (RFD 12, "User interaction"): the operational queries
  Renga knows, whether this host's agent can answer each one, a way to run
  one, and the recent runs with who ran them.

  A query goes to the most recently heard-from active agent on the host that
  offers it. Whether one can run says why not when it cannot: the
  organization has it off, no agent here offers it, or the viewer lacks
  `queries.run` (and `queries.run_sensitive` for a sensitive query).

  Opening a run shows its result, rendered from the query's result schema:
  its list as a table and its other fields beside it. A run whose payload the
  viewer may not read shows only who ran it and how it ended (RFD 12,
  "Authorization"). The page re-reads when the organization's jobs change,
  so a run fills in when its agent reports.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.InventoryComponents
  import RengaWeb.JobComponents

  alias Renga.Authorization
  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Job
  alias Renga.Jobs.Query
  alias Renga.Jobs.Query.Schema
  alias RengaWeb.Format

  @reload_after_ms 300
  @recent_runs 20
  # The hosts an agent runs on; InventoryComponents shows the tab for these.
  @query_kinds ~w(server vm)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    resource = Inventory.get_operational_resource!(scope, id)

    if resource.kind in @query_kinds do
      if connected?(socket), do: Jobs.Changes.subscribe(scope)

      {:ok,
       socket
       |> assign(
         resource: resource,
         page_title: "#{resource.name} queries",
         hardware?: Catalog.hardware_assignable_resource?(resource),
         reload_timer: nil,
         choice: nil,
         run_form: run_form(%{}),
         run_error: nil,
         run: nil
       )
       |> load_queries()
       |> load_runs()}
    else
      {:ok, push_navigate(socket, to: ~p"/inventory/#{resource}")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load_run(socket, params["run"])}

  @impl true
  # Choosing and running each read the host's agents again, so a run goes to
  # whichever offering agent was heard from most recently at that moment,
  # and the panel names that agent, not the one current when the page loaded.
  def handle_event("choose", %{"key" => key}, socket) do
    socket = load_queries(socket)

    {:noreply,
     assign(socket, choice: current_choice(socket, key), run_form: run_form(%{}), run_error: nil)}
  end

  def handle_event("run", params, socket) do
    socket = load_queries(socket)
    choice = socket.assigns.choice && current_choice(socket, socket.assigns.choice.key)
    socket = assign(socket, :choice, choice)
    %{current_scope: scope, resource: resource} = socket.assigns
    values = Map.get(params, "query", %{})

    case choice && choice.agent do
      nil ->
        {:noreply, assign(socket, run_error: "No agent on this host offers this query.")}

      agent ->
        parameters = typed_parameters(choice.module, values)

        case Jobs.create_job(scope, agent.id, choice.key, parameters, resource_id: resource.id) do
          {:ok, job} ->
            {:noreply,
             socket
             |> assign(choice: nil, run_error: nil)
             |> close_overlay("query-panel")
             |> load_runs()
             |> push_patch(to: run_path(resource, job))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, run_form: run_form(values, changeset.errors))}

          {:error, reason} ->
            {:noreply, assign(socket, run_error: run_error(reason))}
        end
    end
  end

  @impl true
  def handle_info({:jobs_changed, _organization_id}, %{assigns: %{reload_timer: nil}} = socket) do
    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  def handle_info({:jobs_changed, _organization_id}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket) do
    run_id = socket.assigns.run && socket.assigns.run.id

    {:noreply,
     socket
     |> assign(:reload_timer, nil)
     |> load_runs()
     |> load_run(run_id)}
  end

  # Each query with the agent that would answer it and, when it cannot run
  # here, why not.
  defp load_queries(socket) do
    %{current_scope: scope, resource: resource} = socket.assigns
    agents = Jobs.list_resource_agents(scope, resource.id)
    allowed = Jobs.get_settings(scope.organization).allowed_capabilities

    queries =
      Enum.map(Query.all(), fn module ->
        key = Capability.key(module)
        agent = Enum.find(agents, &(&1.status == "active" and key in &1.capabilities))
        missing = Enum.reject(module.required_permissions(), &Authorization.allowed?(scope, &1))

        unavailable =
          cond do
            key not in allowed -> "Off in this organization"
            is_nil(agent) -> "No agent here offers it"
            missing != [] -> "Needs #{Enum.join(missing, " and ")}"
            true -> nil
          end

        %{
          key: key,
          slug: slug(module),
          module: module,
          agent: agent,
          unavailable: unavailable
        }
      end)

    assign(socket, queries: queries, agents?: agents != [])
  end

  defp current_choice(socket, key), do: Enum.find(socket.assigns.queries, &(&1.key == key))

  defp load_runs(socket) do
    %{current_scope: scope, resource: resource} = socket.assigns

    runs =
      Jobs.list_jobs(scope,
        resource_id: resource.id,
        capability_names: Enum.map(Query.all(), & &1.name()),
        limit: @recent_runs
      )

    assign(socket, :runs, runs)
  end

  defp load_run(socket, nil), do: assign(socket, :run, nil)

  defp load_run(socket, id) do
    %{current_scope: scope, resource: resource} = socket.assigns

    with %Job{resource_id: resource_id} = job when resource_id == resource.id <-
           Jobs.get_job(scope, id, preload: [:agent, :requested_by_user]),
         module when not is_nil(module) <- query_module(job) do
      assign(socket, :run, %{id: job.id, job: job, module: module})
    else
      _missing ->
        socket
        |> assign(:run, nil)
        |> put_flash(:error, "That run no longer exists; runs are kept for a limited time")
        |> push_patch(to: ~p"/inventory/#{resource}/queries")
    end
  end

  defp query_module(%Job{} = job) do
    case Renga.Jobs.Registry.fetch(Job.capability_key(job)) do
      {:ok, module} -> if Query.query?(module), do: module
      {:error, _unknown} -> nil
    end
  end

  defp run_path(resource, job), do: ~p"/inventory/#{resource}/queries?#{[run: job.id]}"

  defp slug(module), do: module.name() |> String.replace_prefix("query.", "")

  defp run_form(values, errors \\ []), do: to_form(values, as: :query, errors: errors)

  # The form sends strings; the schema wants integers and booleans. A blank
  # optional field is left out, and a value that does not parse is passed
  # through for the schema to refuse.
  defp typed_parameters(module, values) do
    for {name, type, _required?} <- Query.parameter_fields(module),
        value = Map.get(values, name),
        value not in [nil, ""],
        into: %{} do
      {name, typed(unwrap(type), value)}
    end
  end

  defp typed({:integer, _opts}, value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp typed(:integer, value), do: typed({:integer, []}, value)
  defp typed(:boolean, value), do: value == "true"
  defp typed(_type, value), do: value

  defp unwrap({:nullable, type}), do: type
  defp unwrap(type), do: type

  defp run_error(:capability_not_allowed), do: "This organization has this query off."
  defp run_error(:capability_not_advertised), do: "The agent no longer offers this query."
  defp run_error(:agent_disabled), do: "This host's agent is disabled."
  defp run_error(:forbidden), do: "You no longer hold the permissions this query needs."

  defp run_error(:rate_limited),
    do: "Too many jobs were requested just now. Try again in a minute."

  defp run_error(_reason), do: "The query could not be requested. Reload and try again."

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
      <.resource_frame resource={@resource} tab={:queries} hardware?={@hardware?}>
        <div id="resource-queries" class="space-y-8">
          <p
            :if={!@agents?}
            id="queries-no-agent"
            class="rounded-lg border border-dashed border-edge px-4 py-10 text-center text-sm text-fg-muted"
          >
            No agent reports on this host, so nothing here can answer a query.
          </p>

          <section aria-labelledby="query-list-heading" class="space-y-2">
            <h2 id="query-list-heading" class="text-sm font-semibold">Queries</h2>
            <.table id="query-list" rows={@queries} row_id={&"query-#{&1.slug}"} overflow="clip">
              <:col :let={query} label="Query" class="font-medium @3xl:w-44">
                {query.module.title()}
              </:col>
              <:col :let={query} label="Answers" class="text-fg-muted" hide_below="3xl">
                {query.module.summary()}
              </:col>
              <:col :let={query} label="Sensitivity" class="w-28" hide_below="xl">
                <span id={"query-#{query.slug}-sensitivity"}>
                  {sensitivity_label(query.module.sensitivity())}
                </span>
              </:col>
              <:col :let={query} label="Status" class="w-32 @3xl:w-56">
                <span
                  id={"query-#{query.slug}-status"}
                  title={query.unavailable}
                  class={if(query.unavailable, do: "text-fg-muted", else: "text-fg")}
                >
                  {query.unavailable || "Ready"}
                </span>
              </:col>
              <:col :let={query} class="w-20 text-right">
                <.button
                  :if={is_nil(query.unavailable)}
                  id={"query-#{query.slug}-run"}
                  size="sm"
                  phx-click={
                    "choose" |> JS.push(value: %{key: query.key}) |> show_overlay("query-panel")
                  }
                >
                  Run
                </.button>
              </:col>
            </.table>
          </section>

          <.run_result :if={@run} run={@run} viewer_id={@current_scope.user.id} />

          <section aria-labelledby="query-runs-heading" class="space-y-2">
            <h2 id="query-runs-heading" class="text-sm font-semibold">Recent runs</h2>
            <.table
              id="query-runs"
              rows={@runs}
              row_id={&"query-run-#{&1.id}"}
              row_patch={&run_path(@resource, &1)}
              row_selected={&(@run && &1.id == @run.id)}
              overflow="clip"
            >
              <:col :let={job} label="Query" class="w-36 font-medium @3xl:w-44">
                {Jobs.title(job)}
              </:col>
              <:col :let={job} label="Asked" class="text-fg-muted" hide_below="3xl">
                {asked(job) || "—"}
              </:col>
              <:col :let={job} label="Ran by" class="w-48 text-fg-muted" hide_below="xl">
                {requester(job, @current_scope.user.id)}
              </:col>
              <:col :let={job} label="When" class="w-36 text-fg-muted" hide_below="lg">
                <time datetime={DateTime.to_iso8601(job.inserted_at)}>
                  {when_label(job.inserted_at)}
                </time>
              </:col>
              <:col :let={job} label="State" class="w-36 @3xl:w-40">
                <.job_state job={job} id={"query-run-#{job.id}-state"} />
              </:col>
              <:col :let={job} label="Detail" class="text-xs text-fg-muted" hide_below="5xl">
                {detail(job) || "—"}
              </:col>
              <:empty>No queries have run on this host in the retention period.</:empty>
            </.table>
          </section>
        </div>
      </.resource_frame>

      <.side_panel id="query-panel" title={(@choice && @choice.module.title()) || "Run a query"}>
        <.form
          :if={@choice}
          for={@run_form}
          id="query-form"
          phx-submit="run"
          class="space-y-4"
        >
          <p class="-mt-2 text-sm text-fg-muted">{@choice.module.summary()}</p>
          <%!-- Names come from the query's own schema, so the atoms are
                bounded; they may not exist yet on a fresh node. --%>
          <div :for={{name, type, required?} <- Query.parameter_fields(@choice.module)}>
            <.parameter_input
              field={@run_form[String.to_atom(name)]}
              type={unwrap(type)}
              required?={required?}
            />
          </div>
          <p
            :if={Query.parameter_fields(@choice.module) == []}
            class="text-sm text-fg-muted"
          >
            It takes no parameters.
          </p>
          <p :if={@run_error} id="query-run-error" role="alert" class="text-sm text-crit">
            {@run_error}
          </p>
          <p class="text-xs text-fg-muted">
            Runs on {agent_name(@choice.agent)}, which answers once it next checks in. The result
            and who ran it stay with the job, readable by holders of <span class="font-mono">{Enum.join(@choice.module.required_permissions(), " and ")}</span>.
          </p>
        </.form>
        <:footer>
          <.button type="button" phx-click={hide_overlay("query-panel")}>Cancel</.button>
          <.button
            id="query-run-submit"
            variant="primary"
            form="query-form"
            phx-disable-with="Requesting…"
          >
            Run query
          </.button>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :any, required: true
  attr :required?, :boolean, required: true

  defp parameter_input(%{type: {:integer, opts}} = assigns) do
    assigns = assign(assigns, min: opts[:min], max: opts[:max])

    ~H"""
    <.input
      field={@field}
      type="number"
      label={label(@field.field)}
      min={@min}
      max={@max}
      placeholder={unless @required?, do: "Any"}
    />
    """
  end

  defp parameter_input(%{type: :integer} = assigns),
    do: parameter_input(%{assigns | type: {:integer, []}})

  defp parameter_input(%{type: :boolean} = assigns) do
    ~H"""
    <.input field={@field} type="checkbox" label={label(@field.field)} />
    """
  end

  defp parameter_input(%{type: {:enum, values}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <.input
      field={@field}
      type="select"
      label={label(@field.field)}
      prompt={unless @required?, do: "Any"}
      options={@values}
    />
    """
  end

  defp parameter_input(assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label={label(@field.field)}
      placeholder={unless @required?, do: "Any"}
      autocomplete="off"
    />
    """
  end

  @acronyms %{"fs" => "FS", "pid" => "PID", "vrf" => "VRF"}

  # A field's name as a label: `fs_type` reads "FS type", and a unit the
  # value already shows (`size_bytes`, `offset_us`) is left off.
  defp label(field) do
    <<first::utf8, rest::binary>> =
      field
      |> to_string()
      |> String.replace(~r/_(bytes|us)$/, "")
      |> String.split("_")
      |> Enum.map_join(" ", &Map.get(@acronyms, &1, &1))

    String.upcase(<<first::utf8>>) <> rest
  end

  attr :run, :map, required: true
  attr :viewer_id, :string, required: true

  defp run_result(assigns) do
    assigns =
      assign(assigns,
        job: assigns.run.job,
        parts: result_parts(assigns.run.module, assigns.run.job)
      )

    ~H"""
    <section id="query-result" aria-labelledby="query-result-heading" class="space-y-3">
      <div class="flex items-baseline justify-between gap-4">
        <h2 id="query-result-heading" class="text-sm font-semibold">
          {Jobs.title(@job)}
          <span :if={asked(@job)} class="ml-1 font-normal text-fg-muted">· {asked(@job)}</span>
        </h2>
        <.link
          patch={~p"/inventory/#{@job.resource_id}/queries"}
          class="text-sm text-link hover:underline"
        >
          Close
        </.link>
      </div>
      <p id="query-result-meta" class="text-sm text-fg-muted">
        <.job_state job={@job} id="query-result-state" />
        · ran by {requester(@job, @viewer_id)} · {when_label(@job.inserted_at)}
        <span :if={@job.agent}>· on {agent_name(@job.agent)}</span>
      </p>

      <p :if={@job.payload_hidden} id="query-result-hidden" class="text-sm text-fg-muted">
        Its parameters and result need
        <span class="font-mono text-xs text-fg">
          {Enum.join(Jobs.payload_permissions(@job), " and ")}
        </span>
      </p>
      <p
        :if={!@job.payload_hidden and @job.state != "succeeded" and detail(@job)}
        id="query-result-detail"
        class="text-sm text-fg-muted"
      >
        {detail(@job)}
      </p>

      <div :if={@parts} class="space-y-3">
        <dl :if={@parts.scalars != []} id="query-result-fields" class="-mx-2">
          <div
            :for={{name, value} <- @parts.scalars}
            id={"query-result-field-#{name}"}
            class="grid min-h-8 grid-cols-[10rem_minmax(0,1fr)] items-center gap-2 px-2 text-sm"
          >
            <dt class="text-fg-muted">{label(name)}</dt>
            <dd class="min-w-0 truncate">{format_value(name, value)}</dd>
          </div>
        </dl>
        <div :for={list <- @parts.lists} class="space-y-2">
          <p :if={length(@parts.lists) > 1} class="text-xs font-medium text-fg-muted">
            {label(list.name)}
          </p>
          <.table
            id={"query-result-#{list.name}"}
            rows={Enum.with_index(list.rows)}
            row_id={fn {_row, index} -> "query-result-#{list.name}-#{index}" end}
          >
            <:col
              :let={{row, _index}}
              :for={{column, _type, _required?} <- list.columns}
              label={label(column)}
            >
              <span class={value_class(row[column])}>{format_value(column, row[column])}</span>
            </:col>
            <:empty>Nothing matched.</:empty>
          </.table>
        </div>
        <p :if={@parts.truncated?} id="query-result-truncated" class="text-sm text-warn-text">
          The agent cut this list short to fit the result size limit. Narrow the query to see the rest.
        </p>
      </div>
    </section>
    """
  end

  # A succeeded run's result, split the way its schema reads: lists of
  # objects as tables, other fields as properties, and `truncated` as a note.
  defp result_parts(module, %Job{state: "succeeded", payload_hidden: false, result: %{} = result}) do
    {:object, _fields} = schema = module.result_schema()

    Enum.reduce(Schema.fields(schema), %{scalars: [], lists: [], truncated?: false}, fn
      {"truncated", :boolean, _required?}, parts ->
        %{parts | truncated?: result["truncated"] == true}

      {name, {:list, {:object, _} = item, _opts}, _required?}, parts ->
        list = %{name: name, columns: Schema.fields(item), rows: result[name] || []}
        %{parts | lists: parts.lists ++ [list]}

      {name, _type, _required?}, parts ->
        %{parts | scalars: parts.scalars ++ [{name, result[name]}]}
    end)
  end

  defp result_parts(_module, _job), do: nil

  # What a run asked, in the order its schema declares: `port 22, failed
  # only`. Hidden or absent parameters ask nothing.
  defp asked(%Job{payload_hidden: true}), do: nil

  defp asked(%Job{parameters: parameters} = job) when map_size(parameters) > 0 do
    with module when not is_nil(module) <- query_module(job),
         [_ | _] = terms <-
           for(
             {name, _type, _required?} <- Query.parameter_fields(module),
             term = asked_term(name, Map.get(parameters, name)),
             do: term
           ) do
      Enum.join(terms, ", ")
    else
      _nothing -> nil
    end
  end

  defp asked(%Job{}), do: nil

  defp asked_term(_name, nil), do: nil
  defp asked_term(_name, false), do: nil
  defp asked_term(name, true), do: Format.humanize(name)
  defp asked_term(name, value), do: "#{Format.humanize(name)} #{value}"

  defp format_value(_name, nil), do: "—"
  defp format_value(_name, true), do: "Yes"
  defp format_value(_name, false), do: "No"

  defp format_value(name, value) when is_integer(value) do
    cond do
      String.ends_with?(name, "_bytes") -> bytes(value)
      String.ends_with?(name, "_us") -> "#{value} µs"
      true -> Integer.to_string(value)
    end
  end

  defp format_value(_name, value), do: to_string(value)

  defp value_class(value) when is_integer(value), do: "font-mono tabular-nums"
  defp value_class(nil), do: "text-fg-subtle"
  defp value_class(_value), do: nil

  defp bytes(value) when value < 1024, do: "#{value} B"
  defp bytes(value), do: bytes(value / 1024, ~w(KiB MiB GiB TiB PiB))

  defp bytes(size, [_unit | [_ | _] = larger]) when size >= 1024, do: bytes(size / 1024, larger)
  defp bytes(size, [unit | _larger]), do: "#{:erlang.float_to_binary(size, decimals: 1)} #{unit}"

  defp sensitivity_label(:inventory), do: "Inventory"
  defp sensitivity_label(:sensitive), do: "Sensitive"

  defp agent_name(%{name: name}) when is_binary(name), do: name
  defp agent_name(_agent), do: "this host's agent"
end
