defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.CollectionClocks

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Collectors")
     |> assign(:show_new_key?, false)
     |> assign(:issued_token, nil)
     |> assign(:key_form, key_form())
     |> stream_configure(:sources, dom_id: &"collector-#{&1.id}")
     |> stream_configure(:intake_api_keys, dom_id: &"intake-key-#{&1.id}")
     |> schedule_refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    disconnected_only? = params["disconnected"] == "true"

    {:noreply,
     socket
     |> assign(:disconnected_only?, disconnected_only?)
     |> assign(:filter_form, to_form(%{"disconnected" => disconnected_only?}, as: :filters))
     |> load_operations()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    path =
      if filters["disconnected"] == "true",
        do: ~p"/settings/collectors?disconnected=true",
        else: ~p"/settings/collectors"

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("new_intake_key", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_key?, true)
     |> assign(:issued_token, nil)
     |> assign(:key_form, key_form())}
  end

  def handle_event("cancel_intake_key", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_key?, false)
     |> assign(:issued_token, nil)
     |> assign(:key_form, key_form())}
  end

  def handle_event("validate_intake_key", %{"intake_api_key" => params}, socket) do
    {:noreply, assign(socket, :key_form, to_form(params, as: :intake_api_key))}
  end

  def handle_event("create_intake_key", %{"intake_api_key" => params}, socket) do
    case Inventory.create_intake_api_key(socket.assigns.current_scope, params) do
      {:ok, {_key, token}} ->
        {:noreply,
         socket
         |> assign(:issued_token, token)
         |> assign(:key_form, key_form())
         |> load_operations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :key_form, to_form(changeset, as: :intake_api_key))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage intake keys")}
    end
  end

  def handle_event("revoke_intake_key", %{"id" => key_id}, socket) do
    case Inventory.revoke_intake_api_key(socket.assigns.current_scope, key_id) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intake API key revoked")
         |> load_operations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke intake API key")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load_operations() |> schedule_refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:collectors}
    >
      <.settings_page
        id="collector-operations"
        title="Collectors"
        description="Installations appear here once they authenticate with an organization intake key."
        class="max-w-5xl"
      >
        <:actions>
          <.button
            :if={Inventory.collector_manager?(@current_scope)}
            id="new-intake-key-button"
            variant="primary"
            phx-click="new_intake_key"
          >
            <.icon name="hero-key-mini" class="size-4" /> Create intake key
          </.button>
        </:actions>

        <section id="intake-key-management" class="space-y-3" aria-labelledby="intake-keys-heading">
          <div>
            <h2 id="intake-keys-heading" class="text-sm font-medium text-fg">
              Organization intake keys
            </h2>
            <p class="mt-1 text-xs text-fg-muted">
              Several active keys let a whole fleet rotate without downtime.
            </p>
          </div>

          <div
            :if={@show_new_key?}
            id="new-intake-key-panel"
            class="rounded-lg border border-edge bg-surface"
          >
            <div class="flex items-start justify-between gap-4 border-b border-edge px-4 py-3">
              <div>
                <h3 class="text-sm font-medium text-fg">Create an intake API key</h3>
                <p class="mt-0.5 text-xs text-fg-muted">
                  One key can be deployed to every collector in this organization.
                </p>
              </div>
              <button
                id="cancel-intake-key"
                type="button"
                phx-click="cancel_intake_key"
                aria-label="Close intake key setup"
                class="grid min-h-tap min-w-tap size-8 shrink-0 cursor-pointer place-items-center rounded-md text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div :if={is_nil(@issued_token)} class="p-4">
              <.form
                for={@key_form}
                id="new-intake-key-form"
                phx-change="validate_intake_key"
                phx-submit="create_intake_key"
                class="max-w-md"
              >
                <.input
                  field={@key_form[:name]}
                  type="text"
                  label="Key name"
                  placeholder="Production fleet"
                  autocomplete="off"
                />
                <.button id="create-intake-key-button" type="submit" variant="primary">
                  Create key
                </.button>
              </.form>
            </div>

            <div :if={@issued_token} id="intake-key-credentials" class="space-y-4 p-4">
              <div class="flex gap-2.5 rounded-md bg-sunken px-3 py-2">
                <.icon name="hero-check-circle-mini" class="mt-0.5 size-4 shrink-0 text-ok" />
                <div>
                  <p class="text-sm font-medium text-fg">Intake key created</p>
                  <p class="text-xs text-fg-muted">
                    Save it now. Renga stores only its hash and cannot show it again.
                  </p>
                </div>
              </div>
              <div class="flex items-center gap-3 rounded-md border border-edge px-3 py-2">
                <div class="min-w-0 flex-1">
                  <p class="text-xs text-fg-muted">Intake API key</p>
                  <p id="issued-intake-key" class="mt-1 break-all font-mono text-xs text-fg">
                    {@issued_token}
                  </p>
                </div>
                <button
                  id="copy-intake-key"
                  type="button"
                  phx-hook="CopyToClipboard"
                  data-copy-target="#issued-intake-key"
                  data-copy-status="#copy-intake-key-status"
                  aria-label="Copy intake API key"
                  class="grid min-h-tap min-w-tap size-8 shrink-0 cursor-pointer place-items-center rounded-md border border-edge bg-surface text-fg-muted transition-colors hover:bg-sunken hover:text-fg focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
                >
                  <span data-copy-icon><.icon name="hero-clipboard" class="size-4" /></span>
                  <span data-copied-icon class="hidden">
                    <.icon name="hero-check" class="size-4 text-ok" />
                  </span>
                </button>
                <span
                  id="copy-intake-key-status"
                  class="sr-only"
                  role="status"
                  aria-live="polite"
                  aria-atomic="true"
                />
              </div>
              <div class="rounded-md bg-sunken px-3 py-2">
                <p class="mb-1.5 font-mono text-xs text-fg-muted">agent.toml</p>
                <code class="block break-all font-mono text-xs leading-6 text-fg">
                  <span class="block">renga_url = "{RengaWeb.Endpoint.url()}"</span>
                  <span class="block">intake_api_key = "{@issued_token}"</span>
                </code>
              </div>
              <.button id="finish-intake-key-setup" phx-click="cancel_intake_key">
                I saved this key
              </.button>
            </div>
          </div>

          <div
            id="intake-api-keys"
            phx-update="stream"
            class="divide-y divide-line rounded-lg border border-edge bg-surface"
          >
            <p
              id="intake-api-keys-empty"
              class="hidden px-4 py-8 text-center text-sm text-fg-muted only:block"
            >
              No intake keys yet.
            </p>
            <div
              :for={{id, key} <- @streams.intake_api_keys}
              id={id}
              class="flex flex-wrap items-center gap-3 px-3 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium text-fg">{key.name}</p>
                <p class="text-xs text-fg-muted">Created {format_time(key.inserted_at)}</p>
              </div>
              <span class={[
                "inline-flex items-center gap-1.5 text-xs font-medium",
                if(key.status == "active", do: "text-ok", else: "text-fg-muted")
              ]}>
                <span class={[
                  "size-1.5 rounded-full",
                  if(key.status == "active", do: "bg-ok", else: "bg-unknown")
                ]} />
                {String.capitalize(key.status)}
              </span>
              <.button
                :if={key.status == "active" && Inventory.collector_manager?(@current_scope)}
                id={"revoke-intake-key-#{key.id}"}
                size="sm"
                variant="ghost"
                class="text-crit"
                phx-click="revoke_intake_key"
                phx-value-id={key.id}
                data-confirm="Revoke this shared key? Every collector still using it will be rejected."
              >
                Revoke
              </.button>
            </div>
          </div>
        </section>

        <section id="collector-list" class="space-y-3" aria-labelledby="collectors-heading">
          <div class="flex flex-wrap items-end justify-between gap-3">
            <div>
              <h2 id="collectors-heading" class="text-sm font-medium text-fg">
                Discovered installations
              </h2>
              <p class="mt-1 text-xs text-fg-muted">
                Health and inventory provenance stay specific to each installation.
              </p>
            </div>
            <.form for={@filter_form} id="collector-filters" phx-change="filter">
              <.input field={@filter_form[:disconnected]} type="checkbox" label="Disconnected only" />
            </.form>
          </div>

          <%!-- One line per collector, with times and counts inline after each
                state (docs/design-system.md, "Overflow"). As the table narrows
                it drops the installation id (already in the name), then the
                resource, jobs, queue and inventory; the name and connection
                always stay. --%>
          <.table
            id="collectors"
            rows={@streams.sources}
            overflow="clip"
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={{_id, source}} label="Collector">
              <span class="font-medium">{source.name}</span>
              <span class="ml-1.5 font-mono text-xs text-fg-muted">
                {collector_version(source)}
              </span>
            </:col>
            <:col :let={{_id, source}} label="Connection" class="w-40 @2xl:w-64">
              <span id={"collector-connection-#{source.id}"}>
                <.collector_state_pill source={source} />
                <span class="ml-1.5 font-mono text-xs text-fg-muted">
                  contact {format_time(collector_agent(source).last_contacted_at)} · {collector_lease_expiry(
                    source
                  )}
                </span>
              </span>
            </:col>
            <:col :let={{_id, source}} label="Resource" class="w-40" hide_below="5xl">
              <.link
                :if={Map.get(@resource_by_source, source.id)}
                navigate={~p"/inventory/#{Map.fetch!(@resource_by_source, source.id).id}"}
                class="rounded-sm text-link hover:underline focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
              >
                {Map.fetch!(@resource_by_source, source.id).display_name ||
                  Map.fetch!(@resource_by_source, source.id).name}
              </.link>
              <span
                :if={is_nil(Map.get(@resource_by_source, source.id))}
                class="text-xs text-fg-subtle"
              >
                No resource reported
              </span>
            </:col>
            <:col
              :let={{_id, source}}
              label="Installation"
              class="w-32 font-mono text-xs text-fg-muted"
              hide_below="5xl"
            >
              {short_installation_id(collector_agent(source).installation_id)}
            </:col>
            <:col :let={{_id, source}} label="Inventory" class="w-64" hide_below="xl">
              <span id={"collector-inventory-#{source.id}"}>
                <.collector_inventory clocks={Map.get(@clocks_by_source, source.id)} />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Accepts jobs" class="w-32" hide_below="4xl">
              <span id={"collector-jobs-#{source.id}"}>
                <.collector_jobs
                  id={"collector-jobs-#{source.id}-list"}
                  agent={collector_agent(source)}
                />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Delivery queue" class="w-36" hide_below="2xl">
              <span id={"collector-queue-#{source.id}"}>
                <.collector_queue queue={Agent.observation_queue(collector_agent(source))} />
              </span>
            </:col>
            <:empty>No discovered collectors match this view.</:empty>
          </.table>
        </section>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :source, :map, required: true

  defp collector_state_pill(assigns) do
    state = if disconnected?(collector_agent(assigns.source)), do: :disconnected, else: :connected
    assigns = assign(assigns, :state, state)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-medium",
      if(@state == :connected, do: "text-ok", else: "text-crit")
    ]}>
      <%!-- A dot when connected and a square when not, so the state reads without color. --%>
      <span class={[
        "size-1.5",
        if(@state == :connected, do: "rounded-full bg-ok", else: "bg-crit")
      ]} />
      {if(@state == :connected, do: "Connected", else: "Disconnected")}
    </span>
    """
  end

  attr :clocks, CollectionClocks, default: nil

  # Accepted and reconciled are separate clocks (RFD 1): a report Renga took
  # in but could not reconcile does not make the inventory it shows current.
  defp collector_inventory(assigns) do
    ~H"""
    <%= if @clocks do %>
      <span :if={@clocks.latest_outcome == "failed"} class="mr-1.5 text-xs font-medium text-crit">
        Latest report failed to reconcile
      </span>
      <span
        :if={@clocks.latest_outcome in [nil, "pending", "running"]}
        class="mr-1.5 text-xs text-fg-muted"
      >
        Latest report not reconciled yet
      </span>
      <span class="font-mono text-xs text-fg-muted">
        accepted {format_time(@clocks.accepted_at)} · reconciled {format_time(
          @clocks.reconciled_observed_at
        )}
      </span>
    <% else %>
      <span class="text-xs text-fg-subtle">No inventory yet</span>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :agent, Agent, required: true

  # The job capabilities the agent advertised at its last check-in: those it
  # has compiled in and its own [jobs] policy enables (RFD 9). Unversioned
  # entries such as host.inventory say what it reports, not jobs it runs.
  defp collector_jobs(assigns) do
    assigns =
      assign(assigns, :keys, Enum.filter(assigns.agent.capabilities, &String.contains?(&1, "@")))

    ~H"""
    <span :if={@keys == []} class="text-xs text-fg-subtle">None enabled</span>
    <.chip_list :if={@keys != []} id={@id} label="Accepts jobs" items={@keys}>
      <:detail :let={key}>
        <span class="font-mono">{key}</span>
        <span class="text-fg-muted">{job_capability_summary(key)}</span>
      </:detail>
    </.chip_list>
    """
  end

  defp job_capability_summary(key) do
    case Renga.Jobs.Registry.fetch(key) do
      {:ok, capability} -> "#{capability.title()} · #{capability.risk_class()}"
      {:error, _unknown} -> "Unknown to Renga"
    end
  end

  attr :queue, :map, required: true

  # Observations the agent holds on disk because Renga has not accepted them yet,
  # as of its latest check-in. A backlog means inventory here is older than the
  # host's; drops mean some observations will never arrive.
  defp collector_queue(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@queue) -> %>
        <span class="text-xs text-fg-subtle">Not reported</span>
      <% @queue.entries == 0 -> %>
        <span class="text-xs text-fg-muted">Empty</span>
      <% true -> %>
        <span class="text-xs font-medium text-warn-text">{@queue.entries} undelivered</span>
        <span class="ml-1.5 font-mono text-xs text-fg-muted">
          oldest {format_age(@queue.oldest_age_seconds)} · {format_bytes(@queue.bytes)}
        </span>
    <% end %>
    <span
      :if={@queue && @queue.dropped > 0}
      class="ml-1.5 text-xs font-medium text-crit"
      title={dropped_breakdown(@queue)}
    >
      {@queue.dropped} dropped since restart
    </span>
    """
  end

  defp load_operations(socket) do
    scope = socket.assigns.current_scope

    sources =
      scope
      |> Inventory.list_operational_sources()
      |> Enum.filter(&(&1.kind == "host_agent" && not is_nil(collector_agent(&1))))
      |> then(fn sources ->
        if socket.assigns.disconnected_only?,
          do: Enum.filter(sources, &disconnected?(collector_agent(&1))),
          else: sources
      end)

    socket
    |> assign(:clocks_by_source, CollectionClocks.by_source(scope))
    |> assign(:resource_by_source, Inventory.latest_resources_by_source(scope))
    |> stream(:intake_api_keys, Inventory.list_intake_api_keys(scope), reset: true)
    |> stream(:sources, sources, reset: true)
  end

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  defp key_form, do: to_form(%{"name" => ""}, as: :intake_api_key)
  defp collector_agent(%{agents: [agent]}), do: agent
  defp collector_agent(_source), do: nil

  defp disconnected?(agent) do
    agent.status != "active" || is_nil(agent.lease) || AgentLease.expired?(agent.lease)
  end

  defp collector_version(source) do
    case collector_agent(source) do
      %{version: version} when is_binary(version) -> "v#{version}"
      _agent -> "Version unknown"
    end
  end

  defp collector_lease_expiry(source) do
    case collector_agent(source) do
      %{lease: nil} -> "No lease"
      %{lease: lease} -> "expires #{format_time(lease.expires_at)}"
    end
  end

  defp short_installation_id(nil), do: "Identity unavailable"

  defp short_installation_id(installation_id) do
    "#{String.slice(installation_id, 0, 8)}…#{String.slice(installation_id, -4, 4)}"
  end

  defp format_age(nil), do: "unknown"
  defp format_age(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_age(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h"
  defp format_age(seconds), do: "#{div(seconds, 86_400)}d"

  defp format_bytes(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp dropped_breakdown(queue) do
    [
      {queue.dropped_for_space, "to make room"},
      {queue.expired, "after seven days"},
      {queue.rejected, "rejected by Renga"},
      {queue.unreadable, "unreadable"}
    ]
    |> Enum.reject(fn {count, _reason} -> count == 0 end)
    |> Enum.map_join(", ", fn {count, reason} -> "#{count} #{reason}" end)
  end

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
