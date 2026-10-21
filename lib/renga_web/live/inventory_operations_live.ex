defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.CollectionClocks
  alias Renga.Inventory.InstallationKeys

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Collectors")
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
     |> assign(:issued_token, nil)
     |> assign(:key_form, key_form())}
  end

  def handle_event("cancel_intake_key", _params, socket) do
    {:noreply,
     socket
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

  def handle_event(
        "approve_installation_key",
        %{"id" => id, "fingerprint" => fingerprint},
        socket
      ) do
    case InstallationKeys.approve(socket.assigns.current_scope, id, fingerprint) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Installation key approved")
         |> load_operations()}

      {:error, :key_changed} ->
        {:noreply,
         socket
         |> put_flash(:error, "The installation presented a different key. Compare it again.")
         |> load_operations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not approve the installation key")}
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
        class="max-w-6xl"
      >
        <:actions>
          <.button
            :if={Inventory.collector_manager?(@current_scope)}
            id="new-intake-key-button"
            variant="primary"
            phx-click={JS.push("new_intake_key") |> show_overlay("new-intake-key-panel")}
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

          <.side_panel
            id="new-intake-key-panel"
            title="Create an intake API key"
            description="One key can be deployed to every collector in this organization."
            on_cancel={JS.push("cancel_intake_key")}
          >
            <div :if={is_nil(@issued_token)}>
              <.form
                for={@key_form}
                id="new-intake-key-form"
                phx-change="validate_intake_key"
                phx-submit="create_intake_key"
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

            <div :if={@issued_token} id="intake-key-credentials" class="space-y-4">
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
              <.button
                id="finish-intake-key-setup"
                phx-click={JS.push("cancel_intake_key") |> hide_overlay("new-intake-key-panel")}
              >
                I saved this key
              </.button>
            </div>
          </.side_panel>

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
                phx-click={show_overlay("revoke-intake-key-#{key.id}-dialog")}
              >
                Revoke
              </.button>
              <.confirm_dialog
                :if={key.status == "active" && Inventory.collector_manager?(@current_scope)}
                id={"revoke-intake-key-#{key.id}-dialog"}
                title="Revoke this shared key?"
                confirm_label="Revoke key"
                on_confirm={JS.push("revoke_intake_key", value: %{id: key.id})}
              >
                Every collector still using it will be rejected.
              </.confirm_dialog>
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
                it drops the installation key (pending keys also reach the
                Inbox), then the installation id (already in the name), the
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
            <:col :let={{_id, source}} label="Connection" class="w-40">
              <span id={"collector-connection-#{source.id}"}>
                <.collector_state_pill source={source} />
                <span class="ml-1.5 font-mono text-xs text-fg-muted">
                  contact {format_time(collector_agent(source).last_contacted_at)} · {collector_lease_expiry(
                    source
                  )}
                </span>
              </span>
            </:col>
            <:col :let={{_id, source}} label="Resource" class="w-32" hide_below="5xl">
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
              class="w-28 font-mono text-xs text-fg-muted"
              hide_below="5xl"
            >
              {short_installation_id(collector_agent(source).installation_id)}
            </:col>
            <:col :let={{_id, source}} label="Installation key" class="w-44" hide_below="6xl">
              <span id={"collector-key-#{source.id}"}>
                <.installation_key_state
                  key={Map.get(@keys_by_agent, collector_agent(source).id)}
                  can_approve?={@can_manage?}
                />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Inventory" class="w-48" hide_below="xl">
              <span id={"collector-inventory-#{source.id}"}>
                <.collector_inventory clocks={Map.get(@clocks_by_source, source.id)} />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Accepts jobs" class="w-28" hide_below="4xl">
              <span id={"collector-jobs-#{source.id}"}>
                <.collector_jobs
                  id={"collector-jobs-#{source.id}-list"}
                  agent={collector_agent(source)}
                />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Delivery queue" class="w-32" hide_below="2xl">
              <span id={"collector-queue-#{source.id}"}>
                <.collector_queue queue={Agent.observation_queue(collector_agent(source))} />
              </span>
            </:col>
            <:empty>No discovered collectors match this view.</:empty>
          </.table>

          <.confirm_dialog
            :for={key <- @pending_keys}
            :if={@can_manage?}
            id={"approve-key-#{key.id}"}
            title="Approve this installation key?"
            confirm_label="Approve key"
            variant="primary"
            on_confirm={
              JS.push("approve_installation_key",
                value: %{id: key.id, fingerprint: key.fingerprint}
              )
            }
          >
            <p>
              Approve only if this matches what <code class="font-mono">renga-agent fingerprint</code>
              prints on the host:
            </p>
            <p class="mt-2 break-all font-mono text-xs text-fg">{key.fingerprint}</p>
          </.confirm_dialog>
        </section>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :key, :any, required: true
  attr :can_approve?, :boolean, required: true

  # An approved key lets the installation run privileged jobs (RFD 13).
  defp installation_key_state(%{key: nil} = assigns) do
    ~H"""
    <span class="text-xs text-fg-subtle">Not presented</span>
    """
  end

  defp installation_key_state(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-center gap-x-1.5">
      <span class={[
        "inline-flex items-center gap-1.5 text-xs font-medium",
        if(@key.status == "approved", do: "text-ok", else: "text-warn-text")
      ]}>
        <span class={[
          "size-1.5 rounded-full",
          if(@key.status == "approved", do: "bg-ok", else: "bg-warn")
        ]} />
        {if @key.status == "approved", do: "Approved", else: "Pending"}
      </span>
      <span class="font-mono text-xs text-fg-muted" title={@key.fingerprint}>
        {short_fingerprint(@key.fingerprint)}
      </span>
      <button
        :if={@key.status == "pending" && @can_approve?}
        id={"approve-key-#{@key.id}-button"}
        type="button"
        phx-click={show_overlay("approve-key-#{@key.id}")}
        class="min-h-tap cursor-pointer text-xs text-link hover:underline"
      >
        Approve
      </button>
    </span>
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
        <span class="min-w-0 break-all font-mono">{key}</span>
        <span class="shrink-0 text-fg-muted">{job_capability_summary(key)}</span>
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

    keys_by_agent =
      InstallationKeys.current_by_agent(scope, Enum.map(sources, &collector_agent(&1).id))

    socket
    |> assign(:can_manage?, Inventory.collector_manager?(scope))
    |> assign(:keys_by_agent, keys_by_agent)
    |> assign(
      :pending_keys,
      keys_by_agent |> Map.values() |> Enum.filter(&(&1.status == "pending"))
    )
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

  defp short_fingerprint("SHA256:" <> digest), do: "SHA256:#{String.slice(digest, 0, 8)}…"

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
