defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Authorization
  alias Renga.Deployment
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.CollectionClocks
  alias Renga.Inventory.CollectorFindings
  alias Renga.Inventory.Collectors
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.InstallationKeys

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Collectors")
     |> assign(:issued_token, nil)
     |> assign(:deployment_id, Deployment.id())
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

  def handle_event("set_guest_without_vm", %{"guest_without_vm" => %{"enabled" => value}}, socket) do
    case CollectorFindings.set_guest_without_vm_findings(
           socket.assigns.current_scope,
           value == "true"
         ) do
      {:ok, enabled?} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(enabled?,
             do: "Guests without a VM will be flagged",
             else: "Guests without a VM are no longer flagged"
           )
         )
         |> load_operations()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not allowed to change organization settings")
         |> load_operations()}
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
            <p :if={@deployment_id} id="intake-key-deployment-id" class="mt-1 text-xs text-fg-muted">
              New keys carry this deployment's identifier, <span class="font-mono text-fg">{@deployment_id}</span>. Older keys keep working; rotate them to add it.
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
                <p class="text-xs text-fg-muted">
                  Created {format_time(key.inserted_at)}
                  <span :if={key.deployment_id} id={"intake-key-#{key.id}-deployment-id"}>
                    · Deployment <span class="font-mono">{key.deployment_id}</span>
                  </span>
                </p>
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

          <%!-- The table drops its key column below the 5xl container size,
                which a page with the sidebar reaches only on wide screens, so
                keys awaiting approval are listed here at every width. --%>
          <div
            :if={@pending_keys != []}
            id="pending-installation-keys"
            aria-labelledby="pending-installation-keys-heading"
            role="region"
            class="rounded-lg border border-edge bg-surface"
          >
            <h3
              id="pending-installation-keys-heading"
              class="border-b border-line px-4 py-2 text-xs font-medium text-fg-muted"
            >
              Installation keys awaiting approval
            </h3>
            <ul class="divide-y divide-line">
              <li
                :for={{key, name} <- @pending_keys}
                id={"pending-key-#{key.id}"}
                class="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-2 text-sm"
              >
                <span class="min-w-0 truncate font-medium text-fg" title={name}>{name}</span>
                <span class="font-mono text-xs text-fg-muted" title={key.fingerprint}>
                  {short_fingerprint(key.fingerprint)}
                </span>
                <button
                  :if={@can_manage?}
                  id={"pending-key-#{key.id}-approve"}
                  type="button"
                  phx-click={show_overlay("approve-key-#{key.id}")}
                  class="ml-auto min-h-tap min-w-tap cursor-pointer text-xs text-link hover:underline"
                >
                  Approve
                </button>
                <span :if={!@can_manage?} class="ml-auto text-xs text-fg-subtle">
                  Needs someone who manages intake keys
                </span>
              </li>
            </ul>
          </div>

          <%!-- One line per collector, with times and counts inline after each
                state (docs/design-system.md, "Overflow"). As the table narrows
                it drops the installation id (already in the name), then the
                installation key, the resource, jobs, queue and inventory; the
                name and connection always stay. The page is max-w-6xl, so the
                installation id shows only if the page grows wider. --%>
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
              hide_below="6xl"
            >
              {short_installation_id(collector_agent(source).installation_id)}
            </:col>
            <:col :let={{_id, source}} label="Installation key" class="w-36" hide_below="5xl">
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
            <:col :let={{_id, source}} label="Power sources" class="w-36" hide_below="3xl">
              <span id={"collector-power-#{source.id}"}>
                <.collector_power_sources
                  id={"collector-power-#{source.id}"}
                  sources={Agent.power_sources(collector_agent(source))}
                />
              </span>
            </:col>
            <:col :let={{_id, source}} label="Delivery queue" class="w-32" hide_below="2xl">
              <span id={"collector-queue-#{source.id}"}>
                <.collector_queue queue={Agent.observation_queue(collector_agent(source))} />
              </span>
              <.collector_telemetry_queue
                id={"collector-telemetry-queue-#{source.id}"}
                queue={Agent.telemetry_queue(collector_agent(source))}
              />
            </:col>
            <:empty>No discovered collectors match this view.</:empty>
          </.table>

          <.confirm_dialog
            :for={{key, _name} <- @pending_keys}
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

        <section
          id="collector-findings-settings"
          class="space-y-3"
          aria-labelledby="collector-findings-heading"
        >
          <div>
            <h2 id="collector-findings-heading" class="text-sm font-medium text-fg">
              Collector findings
            </h2>
            <p class="mt-1 text-xs text-fg-muted">
              Unreachable targets and VMs active on two hypervisors always reach the Inbox. Some findings are only useful once collection covers everything.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3 rounded-lg border border-edge bg-surface px-4 py-3">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium text-fg">Guests without a VM</p>
              <p class="text-xs text-fg-muted">
                Flag KVM guests whose SMBIOS UUID matches no domain on any reporting hypervisor. Turn it on once every hypervisor reports through libvirt, or it flags every guest on the others.
              </p>
            </div>
            <.form
              :if={@can_manage_organization?}
              for={@guest_form}
              id="guest-without-vm-form"
              phx-change="set_guest_without_vm"
            >
              <.input field={@guest_form[:enabled]} type="checkbox" label="Flag them" />
            </.form>
            <span
              :if={!@can_manage_organization?}
              id="guest-without-vm-state"
              class="text-xs text-fg-muted"
            >
              {if @guest_form[:enabled].value, do: "On", else: "Off"}
            </span>
          </div>
        </section>

        <section
          :if={@target_rows != []}
          id="collector-targets"
          class="space-y-3"
          aria-labelledby="collector-targets-heading"
        >
          <div>
            <h2 id="collector-targets-heading" class="text-sm font-medium text-fg">
              Poller targets
            </h2>
            <p class="mt-1 text-xs text-fg-muted">
              The switches and hypervisors each collector module polls, as of each target's latest report. An unreachable target's inventory stays as it was, unknown rather than gone.
            </p>
          </div>

          <%!-- Grouped by collector stream. The target and its state never
                hide; resources, then the times, go first as it narrows. --%>
          <.table
            id="poller-targets"
            rows={@target_rows}
            row_id={fn row -> row.id end}
            row_group={fn row -> row[:header] end}
            overflow="clip"
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={row} label="Target" class="w-2/3 sm:w-auto">
              <span class="font-mono text-xs text-fg">{row.display_key}</span>
            </:col>
            <:col :let={row} label="State" class="w-1/3 sm:w-64">
              <span id={"poller-target-state-#{row.target.id}"}>
                <.target_state_pill target={row.target} />
                <span
                  :if={row.target.status == "unreachable" && row.target.error}
                  class="ml-1.5 hidden text-xs text-fg-muted sm:inline"
                >
                  Connection failed
                </span>
              </span>
            </:col>
            <:col :let={row} label="Resources" class="w-24 tabular-nums" hide_below="3xl">
              <span id={"poller-target-resources-#{row.target.id}"}>{row.resources}</span>
            </:col>
            <:col
              :let={row}
              label="Reached"
              class="w-44 font-mono text-xs text-fg-muted"
              hide_below="xl"
            >
              {format_time(row.target.last_reachable_at)}
            </:col>
            <:col
              :let={row}
              label="Reported"
              class="w-44 font-mono text-xs text-fg-muted"
              hide_below="2xl"
            >
              {format_time(row.target.last_reported_at)}
            </:col>
          </.table>
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
        class="min-h-tap min-w-tap cursor-pointer text-xs text-link hover:underline"
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

  attr :target, CollectorTarget, required: true

  # The state the target's latest report gave it: a dot when reachable and a
  # square when not, like a collector's connection.
  defp target_state_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-medium",
      if(@target.status == "reachable", do: "text-ok", else: "text-crit")
    ]}>
      <span class={[
        "size-1.5",
        if(@target.status == "reachable", do: "rounded-full bg-ok", else: "bg-crit")
      ]} />
      {if(@target.status == "reachable", do: "Reachable", else: "Unreachable")}
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

  attr :id, :string, required: true
  attr :sources, :list, required: true

  # Whether the agent can read each power source on its host (RFD 10). A source
  # it cannot read names what would enable it.
  defp collector_power_sources(%{sources: nil} = assigns) do
    ~H"""
    <span class="text-xs text-fg-subtle">Not reported</span>
    """
  end

  defp collector_power_sources(assigns) do
    ~H"""
    <span class="flex flex-wrap gap-x-2 gap-y-0.5">
      <span
        :for={{source, index} <- Enum.with_index(@sources)}
        id={"#{@id}-#{index}"}
        class="inline-flex items-center gap-1 text-xs"
        title={power_source_hint(source)}
      >
        <span class={["size-1.5 rounded-full", power_source_dot(source.status)]} />
        <span class="font-mono text-fg-muted">{source.source}</span>
        <span class="text-fg">{power_source_status(source.status)}</span>
      </span>
    </span>
    """
  end

  defp power_source_dot("available"), do: "bg-ok"
  defp power_source_dot("unreachable"), do: "bg-crit"
  defp power_source_dot(_status), do: "bg-unknown"

  defp power_source_status("available"), do: "Available"
  defp power_source_status("not_permitted"), do: "Not permitted"
  defp power_source_status("not_present"), do: "Not present"
  defp power_source_status("unreachable"), do: "Unreachable"

  defp power_source_hint(%{source: "hwmon", status: "not_present"}),
    do:
      "No acpi_power_meter or supported power supply sensor. A host running " <>
        "ipmi_exporter can be read by adding it under [[exporters]] in the agent configuration."

  defp power_source_hint(%{source: "hwmon", status: "not_permitted"}),
    do: "The agent cannot read /sys/class/hwmon. Check the service's sandbox settings."

  defp power_source_hint(%{status: "unreachable"}),
    do: "The agent cannot reach this source. Check its address and that it is running."

  defp power_source_hint(%{status: "not_permitted"}),
    do: "The agent is not allowed to read this source. Check its credentials or permissions."

  defp power_source_hint(_source), do: nil

  attr :id, :string, required: true
  attr :queue, :map, required: true

  # Agents without telemetry producers report no telemetry queue, so nothing
  # shows. The queue follows the observation queue on the same line, so the
  # row stays single-line and clips rather than wraps.
  defp collector_telemetry_queue(%{queue: nil} = assigns), do: ~H""

  defp collector_telemetry_queue(assigns) do
    ~H"""
    <span id={@id} class="ml-1.5">
      <span class="text-xs text-fg-subtle">· Telemetry</span>
      <.collector_queue queue={@queue} kind={:telemetry} />
    </span>
    """
  end

  attr :queue, :map, required: true
  attr :kind, :atom, default: :observations

  # Observations the agent holds on disk because Renga has not accepted them yet,
  # as of its latest check-in. A backlog means inventory here is older than the
  # host's; drops mean some observations will never arrive. Telemetry has its
  # own queue (RFD 10), whose drops are readings lost from history.
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
    <%!-- The breakdown is inline text, not a title, so the cell's clip reveal
    shows it when the column is too narrow. --%>
    <span :if={@queue && @queue.dropped > 0} class="ml-1.5 text-xs">
      <span class="font-medium text-crit">{@queue.dropped} dropped since restart</span>
      <span class="text-fg-muted">({dropped_breakdown(@queue, @kind)})</span>
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
    |> assign(:pending_keys, pending_keys(sources, keys_by_agent))
    |> assign(:clocks_by_source, CollectionClocks.by_source(scope))
    |> assign(:resource_by_source, Inventory.latest_resources_by_source(scope))
    |> assign(:target_rows, target_rows(scope))
    |> assign(:can_manage_organization?, Authorization.allowed?(scope, "organization.manage"))
    |> assign(
      :guest_form,
      to_form(%{"enabled" => CollectorFindings.guest_without_vm_findings?(scope)},
        as: :guest_without_vm
      )
    )
    |> stream(:intake_api_keys, Inventory.list_intake_api_keys(scope), reset: true)
    |> stream(:sources, sources, reset: true)
  end

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  # Pending keys with the collector each belongs to, in table order.
  defp pending_keys(sources, keys_by_agent) do
    for source <- sources,
        %{status: "pending"} = key <- [Map.get(keys_by_agent, collector_agent(source).id)],
        do: {key, source.name}
  end

  # Each stream's header row, then one row per target.
  defp target_rows(scope) do
    for {stream, targets} <- Collectors.list_stream_targets(scope),
        row <- [
          stream_header(stream, length(targets)) | Enum.map(targets, &target_row(stream, &1))
        ],
        do: row
  end

  defp stream_header(stream, count) do
    installation =
      case stream.installation_agent do
        %Agent{name: name} when is_binary(name) -> " on #{name}"
        _agent -> ""
      end

    %{
      id: "poller-stream-#{stream.id}",
      header: %{
        label: "#{stream.collector_id} · #{stream_kind(stream.kind)}#{installation}",
        count: count
      }
    }
  end

  defp target_row(stream, {target, resources}) do
    %{
      id: "poller-target-#{target.id}",
      target: target,
      resources: resources,
      display_key:
        if(stream.kind == "vm_provider",
          do: CollectorTarget.display_uri(target.key),
          else: target.key
        )
    }
  end

  defp stream_kind("switch_poller"), do: "Switch poller"
  defp stream_kind("vm_provider"), do: "Hypervisor"
  defp stream_kind(kind), do: kind

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

  defp dropped_breakdown(queue, kind) do
    [
      {queue.dropped_for_space, "to make room"},
      {queue.expired, if(kind == :telemetry, do: "after a day", else: "after seven days")},
      {queue.rejected, "rejected by Renga"},
      {queue.unreadable, "unreadable"}
    ]
    |> Enum.reject(fn {count, _reason} -> count == 0 end)
    |> Enum.map_join(", ", fn {count, reason} -> "#{count} #{reason}" end)
    |> Kernel.<>(dropped_range(queue))
  end

  # Ages as of the agent's last check-in.
  defp dropped_range(%{dropped_ages: {earliest, latest}}),
    do: "; queued #{format_age(earliest)} to #{format_age(latest)} before the last check-in"

  defp dropped_range(_queue), do: ""

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
