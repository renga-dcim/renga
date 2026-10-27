defmodule RengaWeb.QueryFanOutComponent do
  @moduledoc """
  Runs a query across a filtered inventory list (RFD 12, "User
  interaction"): a side panel to choose a query and its parameters, which
  says how many of the matching resources an agent can answer for, and
  starts the batch whose results page it then opens.

  Only queries the organization has on and the viewer holds the permissions
  for are offered. The list's filters, not its page or selection, decide the
  resources, up to `Renga.Jobs.max_batch_size/0` of them.
  """
  use RengaWeb, :live_component

  import RengaWeb.QueryComponents

  alias Renga.Authorization
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Query
  alias RengaWeb.UserAuth

  @impl true
  def mount(socket) do
    # Component-targeted events do not run the parent LiveView's hooks.
    socket =
      attach_hook(socket, :authenticated_access, :handle_event, fn _event, _params, socket ->
        with {:cont, socket} <- UserAuth.refresh_session(socket) do
          UserAuth.refresh_organization_access(socket)
        end
      end)

    {:ok, assign(socket, choice: nil, form: parameters_form(%{}), error: nil, reach: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(:queries, runnable(assigns.current_scope))}
  end

  # Queries the organization has on and the viewer may run.
  defp runnable(scope) do
    allowed = Jobs.get_settings(scope.organization).allowed_capabilities

    for module <- Query.all(),
        Capability.key(module) in allowed,
        Enum.all?(module.required_permissions(), &Authorization.allowed?(scope, &1)),
        do: module
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, socket |> choose(List.first(socket.assigns.queries), %{}) |> assign(:error, nil)}
  end

  def handle_event("change", %{"capability" => key} = params, socket) do
    module = Enum.find(socket.assigns.queries, &(Capability.key(&1) == key))
    values = if module == socket.assigns.choice, do: Map.get(params, "query", %{}), else: %{}
    {:noreply, choose(socket, module, values)}
  end

  def handle_event("run", %{"capability" => key} = params, socket) do
    %{current_scope: scope, list_options: options} = socket.assigns
    values = Map.get(params, "query", %{})

    with module when not is_nil(module) <-
           Enum.find(socket.assigns.queries, &(Capability.key(&1) == key)),
         ids = Inventory.list_operational_resource_ids(scope, options, Jobs.max_batch_size() + 1),
         {:ok, batch} <- Jobs.create_batch(scope, key, form_parameters(module, values), ids) do
      {:noreply, push_navigate(socket, to: ~p"/activity/queries/#{batch.batch_id}")}
    else
      nil ->
        {:noreply, assign(socket, :error, "This query is no longer available to you.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: parameters_form(values, changeset.errors))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, run_error(reason))}
    end
  end

  defp choose(socket, nil, _values), do: assign(socket, choice: nil, reach: nil)

  defp choose(socket, module, values) do
    %{current_scope: scope, list_options: options} = socket.assigns
    ids = Inventory.list_operational_resource_ids(scope, options, Jobs.max_batch_size() + 1)

    reach =
      if length(ids) > Jobs.max_batch_size(),
        do: :too_many,
        else: {map_size(Jobs.batch_targets(scope, Capability.key(module), ids)), length(ids)}

    assign(socket, choice: module, form: parameters_form(values), reach: reach)
  end

  defp run_error(:no_agents), do: "No resource in this list has an agent that offers this query."

  defp run_error(:batch_too_large),
    do: "Narrow the list to #{Jobs.max_batch_size()} resources or fewer."

  defp run_error(:capability_not_allowed), do: "This organization has this query off."
  defp run_error(:forbidden), do: "You no longer hold the permissions this query needs."

  defp run_error(:rate_limited),
    do: "Too many jobs were requested just now. Try again in a minute."

  defp run_error(_reason), do: "The query could not be requested. Reload and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.side_panel
        id="query-fan-out-panel"
        title="Run a query"
        description="Asks every resource this list matches, wherever an agent offers the query."
      >
        <p :if={@queries == []} id="query-fan-out-none" class="text-sm text-fg-muted">
          No query is on in this organization that you can run.
        </p>
        <.form
          :if={@queries != []}
          for={@form}
          id="query-fan-out-form"
          phx-change="change"
          phx-submit="run"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            id="query-fan-out-capability"
            name="capability"
            type="select"
            label="Query"
            value={@choice && Capability.key(@choice)}
            options={Enum.map(@queries, &{&1.title(), Capability.key(&1)})}
          />
          <p :if={@choice} class="-mt-2 text-sm text-fg-muted">{@choice.summary()}</p>
          <.parameter_fields :if={@choice} form={@form} module={@choice} />
          <p id="query-fan-out-reach" class="text-sm">
            <.reach reach={@reach} />
          </p>
          <p :if={@error} id="query-fan-out-error" role="alert" class="text-sm text-crit">
            {@error}
          </p>
        </.form>
        <:footer>
          <.button type="button" phx-click={hide_overlay("query-fan-out-panel")}>Cancel</.button>
          <.button
            :if={@queries != []}
            id="query-fan-out-submit"
            variant="primary"
            form="query-fan-out-form"
            phx-disable-with="Requesting…"
          >
            Run query
          </.button>
        </:footer>
      </.side_panel>
    </div>
    """
  end

  attr :reach, :any, required: true

  defp reach(%{reach: :too_many} = assigns) do
    ~H"""
    <span class="text-warn-text">
      This list matches more than {Jobs.max_batch_size()} resources. Narrow it first.
    </span>
    """
  end

  defp reach(%{reach: {_reachable, 0}} = assigns) do
    ~H"""
    <span class="text-fg-muted">This list matches no resources.</span>
    """
  end

  defp reach(%{reach: {reachable, total}} = assigns) do
    assigns = assign(assigns, reachable: reachable, total: total)

    ~H"""
    <span class="font-mono tabular-nums">{@reachable}</span>
    of <span class="font-mono tabular-nums">{@total}</span>
    {if @total == 1, do: "matching resource has", else: "matching resources have"} an agent that answers it.
    """
  end

  defp reach(assigns), do: ~H""
end
