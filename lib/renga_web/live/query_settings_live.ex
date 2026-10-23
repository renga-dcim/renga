defmodule RengaWeb.QuerySettingsLive do
  @moduledoc """
  Settings → Queries: which operational queries (RFD 12) the organization
  allows. Every query starts off and is enabled one at a time by holders of
  `organization.manage`.

  Enabling a query lets nobody run it on its own. Running one needs RFD 17's
  explicit `queries.run` permission, and a sensitive one `queries.run_sensitive`
  too, issued through a custom role; each host's agent must also enable the
  query in its `[jobs]` policy. The page says so, since all three must line
  up before a query can run.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Authorization
  alias Renga.Jobs
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Query

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: scope} = socket.assigns

    {:ok,
     socket
     |> assign(
       page_title: "Queries",
       queries: Query.all(),
       can_manage?: Authorization.allowed?(scope, "organization.manage")
     )
     |> assign_allowed(Jobs.get_settings(scope.organization))}
  end

  @impl true
  def handle_event("toggle", %{"key" => key, "enabled" => enabled}, socket) do
    %{current_scope: scope} = socket.assigns

    case Jobs.allow_capability(scope, key, enabled == "true") do
      {:ok, settings} ->
        {:noreply, assign_allowed(socket, settings)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners enable and disable queries")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That query could not be changed")}
    end
  end

  defp assign_allowed(socket, settings),
    do: assign(socket, :allowed, MapSet.new(settings.allowed_capabilities))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:queries}
    >
      <.settings_page
        id="queries"
        title="Queries"
        description="Typed, read-only questions an agent answers about its host on demand. Each one stays off until it is enabled here."
      >
        <div id="queries-access" class="rounded-lg border border-edge bg-surface px-3 py-2.5 text-sm">
          <p class="text-fg">
            Enabling a query does not let anyone run it yet.
          </p>
          <p class="mt-1 text-fg-muted">
            Running one needs the <span class="font-mono text-xs text-fg">queries.run</span>
            permission, and a sensitive one
            <span class="font-mono text-xs text-fg">queries.run_sensitive</span>
            too. No built-in role includes them; owners and admins give them through a role in <.link
              navigate={~p"/settings/roles"}
              class="text-link hover:underline"
            >
              Settings → Roles
            </.link>. Each host's agent must also enable the query in its
            <span class="font-mono text-xs text-fg">[jobs]</span>
            policy.
          </p>
        </div>

        <.table
          id="query-list"
          rows={@queries}
          row_id={&"query-#{dom_key(&1)}"}
          overflow="clip"
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={query} label="Query" class="w-48">
            <span class="font-medium text-fg">{query.title()}</span>
          </:col>
          <:col :let={query} label="Answers" hide_below="lg">
            <span class="text-fg-muted">{query.summary()}</span>
          </:col>
          <:col :let={query} label="Sensitivity" class="w-28">
            <span
              id={"query-#{dom_key(query)}-sensitivity"}
              class={if query.sensitivity() == :sensitive, do: "text-fg", else: "text-fg-muted"}
            >
              {if query.sensitivity() == :sensitive, do: "Sensitive", else: "Inventory"}
            </span>
          </:col>
          <:col :let={query} label="Status" class="w-24">
            <span id={"query-#{dom_key(query)}-status"} class="text-fg">
              {if enabled?(@allowed, query), do: "On", else: "Off"}
            </span>
          </:col>
          <:action :let={query}>
            <.button
              :if={@can_manage?}
              id={"query-#{dom_key(query)}-toggle"}
              phx-click="toggle"
              phx-value-key={Capability.key(query)}
              phx-value-enabled={to_string(!enabled?(@allowed, query))}
              variant={if enabled?(@allowed, query), do: "ghost", else: "secondary"}
            >
              {if enabled?(@allowed, query), do: "Disable", else: "Enable"}
            </.button>
          </:action>
        </.table>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp enabled?(allowed, query), do: MapSet.member?(allowed, Capability.key(query))

  # "query.disk_usage@1" -> "disk_usage-1", safe in a DOM id.
  defp dom_key(query),
    do: "#{String.replace_prefix(query.name(), "query.", "")}-#{query.version()}"
end
