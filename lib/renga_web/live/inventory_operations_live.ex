defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Enrollment
  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.Source

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Collectors")
     |> assign(:show_new_collector?, false)
     |> assign(:issued_token, nil)
     |> assign(:issued_action, nil)
     |> assign(:setup_installation_id, nil)
     |> assign(:collector_form, collector_form(socket.assigns.current_scope))
     |> stream_configure(:sources, dom_id: &source_dom_id/1)
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
      if filters["disconnected"] == "true" do
        ~p"/inventory/operations?disconnected=true"
      else
        ~p"/inventory/operations"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("new_collector", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_collector?, true)
     |> assign(:issued_token, nil)
     |> assign(:issued_action, nil)
     |> assign(:setup_installation_id, Ecto.UUID.generate())
     |> assign(:collector_form, collector_form(socket.assigns.current_scope))}
  end

  def handle_event("cancel_new_collector", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_collector?, false)
     |> assign(:issued_token, nil)
     |> assign(:issued_action, nil)
     |> assign(:setup_installation_id, nil)}
  end

  def handle_event("validate_collector", %{"collector" => params}, socket) do
    form =
      socket.assigns.current_scope
      |> collector_changeset(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :collector)

    {:noreply, assign(socket, :collector_form, form)}
  end

  def handle_event("create_collector", %{"collector" => params}, socket) do
    attrs = Map.merge(params, %{"kind" => "host_agent", "status" => "active"})

    case Inventory.create_collector_with_token(socket.assigns.current_scope, attrs) do
      {:ok, {_source, token}} ->
        {:noreply,
         socket
         |> assign(:issued_token, token)
         |> assign(:issued_action, :created)
         |> assign(:collector_form, collector_form(socket.assigns.current_scope))
         |> load_operations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :collector_form, to_form(changeset, as: :collector))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage collectors")}
    end
  end

  def handle_event("rotate_collector", %{"id" => source_id}, socket) do
    installation_id = collector_installation_id(socket.assigns.current_scope, source_id)

    case Inventory.rotate_collector_token(socket.assigns.current_scope, source_id) do
      {:ok, {_source, token}} ->
        {:noreply,
         socket
         |> assign(:show_new_collector?, true)
         |> assign(:issued_token, token)
         |> assign(:issued_action, :rotated)
         |> assign(:setup_installation_id, installation_id || Ecto.UUID.generate())
         |> load_operations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not rotate collector credential")}
    end
  end

  def handle_event("reset_collector", %{"id" => source_id}, socket) do
    case Inventory.reset_collector_enrollment(socket.assigns.current_scope, source_id) do
      {:ok, {_source, token}} ->
        {:noreply,
         socket
         |> assign(:show_new_collector?, true)
         |> assign(:issued_token, token)
         |> assign(:issued_action, :reset)
         |> assign(:setup_installation_id, Ecto.UUID.generate())
         |> load_operations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not reset collector enrollment")}
    end
  end

  def handle_event("revoke_collector", %{"id" => source_id}, socket) do
    case Inventory.revoke_collector_token(socket.assigns.current_scope, source_id) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collector credential revoked")
         |> load_operations()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not revoke collector credential")}
    end
  end

  def handle_event("quarantine_agent_credential", %{"id" => credential_id}, socket) do
    administer_agent_credential(socket, credential_id, :quarantine)
  end

  def handle_event("unquarantine_agent_credential", %{"id" => credential_id}, socket) do
    administer_agent_credential(socket, credential_id, :unquarantine)
  end

  def handle_event("revoke_agent_credential", %{"id" => credential_id}, socket) do
    administer_agent_credential(socket, credential_id, :revoke)
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load_operations() |> schedule_refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="collector-list" class="space-y-8">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">
              Collection plane
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Collectors</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Agent installations that authenticate and report inventory for this organization.
            </p>
          </div>
          <div class="flex flex-col items-start gap-3 sm:items-end">
            <button
              :if={Inventory.collector_manager?(@current_scope)}
              id="new-collector-button"
              type="button"
              phx-click="new_collector"
              class="inline-flex items-center gap-2 rounded-xl bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white shadow-sm shadow-orange-500/20 transition hover:-translate-y-0.5 hover:bg-orange-600"
            >
              <.icon name="hero-plus" class="size-4" /> Add collector
            </button>
            <.form for={@filter_form} id="collector-filters" phx-change="filter">
              <.input
                field={@filter_form[:disconnected]}
                type="checkbox"
                label="Disconnected only"
              />
            </.form>
          </div>
        </header>

        <section
          :if={@show_new_collector?}
          id="new-collector-panel"
          class="overflow-hidden rounded-2xl border border-orange-500/20 bg-base-100 shadow-lg shadow-orange-500/5"
        >
          <div class="flex items-start justify-between gap-4 border-b border-base-content/10 px-6 py-5">
            <div>
              <h2 class="font-semibold tracking-tight">Add a host collector</h2>
              <p class="mt-1 text-sm text-base-content/50">
                Create one credential for one stable agent installation.
              </p>
            </div>
            <button
              id="cancel-new-collector"
              type="button"
              phx-click="cancel_new_collector"
              class="rounded-lg p-2 text-base-content/40 transition hover:bg-base-200 hover:text-base-content"
              aria-label="Close collector setup"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div :if={is_nil(@issued_token)} class="p-6">
            <.form
              for={@collector_form}
              id="new-collector-form"
              phx-change="validate_collector"
              phx-submit="create_collector"
              class="max-w-xl space-y-5"
            >
              <.input
                field={@collector_form[:name]}
                type="text"
                label="Collector name"
                placeholder="framework16-agent"
                autocomplete="off"
              />
              <p class="text-xs leading-5 text-base-content/45">
                Use a name that identifies the installation or the resource it will inventory.
              </p>
              <button
                id="create-collector-button"
                type="submit"
                class="rounded-xl bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
              >
                Create collector
              </button>
            </.form>
          </div>

          <div :if={@issued_token} id="collector-credentials" class="space-y-5 p-6">
            <div class="flex gap-3 rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-emerald-600" />
              <div>
                <p class="text-sm font-semibold">{credential_heading(@issued_action)}</p>
                <p class="mt-1 text-xs leading-5 text-base-content/55">
                  {credential_instructions(@issued_action)}
                </p>
              </div>
            </div>
            <dl class="grid gap-4 lg:grid-cols-2">
              <div class="rounded-xl bg-base-200/70 p-4">
                <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                  Enrollment token
                </dt>
                <dd id="issued-collector-token" class="mt-2 break-all font-mono text-xs">
                  {@issued_token}
                </dd>
              </div>
              <div class="rounded-xl bg-base-200/70 p-4">
                <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                  Installation ID
                </dt>
                <dd id="issued-installation-id" class="mt-2 break-all font-mono text-xs">
                  {@setup_installation_id}
                </dd>
              </div>
            </dl>
            <div class="rounded-xl border border-base-content/10 bg-slate-950 p-4 text-slate-100">
              <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-slate-400">
                agent.toml
              </p>
              <code
                phx-no-curly-interpolation
                class="block whitespace-pre-wrap break-all font-mono text-xs leading-6"
              >
                {"renga_url = \"#{RengaWeb.Endpoint.url()}\"\ntoken = \"#{@issued_token}\"\ninstallation_id = \"#{@setup_installation_id}\""}
              </code>
            </div>
            <button
              id="finish-collector-setup"
              type="button"
              phx-click="cancel_new_collector"
              class="rounded-xl border border-base-content/15 px-4 py-2.5 text-sm font-semibold transition hover:bg-base-200"
            >
              I saved these values
            </button>
          </div>
        </section>

        <section aria-labelledby="collectors-heading" class="space-y-4">
          <h2 id="collectors-heading" class="sr-only">Registered collectors</h2>
          <div class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm">
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-base-content/10 text-left text-sm">
                <thead class="bg-base-200/70 text-xs uppercase tracking-wider text-base-content/45">
                  <tr>
                    <th class="px-5 py-3.5 font-semibold">Collector</th>
                    <th class="px-5 py-3.5 font-semibold">Connection</th>
                    <th class="px-5 py-3.5 font-semibold">Resource</th>
                    <th class="px-5 py-3.5 font-semibold">Authentication</th>
                    <th class="px-5 py-3.5 font-semibold">Last inventory</th>
                    <th class="px-5 py-3.5 text-right font-semibold">Actions</th>
                  </tr>
                </thead>
                <tbody id="collectors" phx-update="stream" class="divide-y divide-base-content/10">
                  <tr id="collectors-empty" class="hidden only:table-row">
                    <td colspan="6" class="px-5 py-12 text-center text-sm text-base-content/45">
                      No collectors match this view.
                    </td>
                  </tr>
                  <tr
                    :for={{id, source} <- @streams.sources}
                    id={id}
                    class="transition hover:bg-orange-500/[0.035]"
                  >
                    <td class="px-5 py-4">
                      <p class="font-semibold">{source.name}</p>
                      <p class="mt-1 font-mono text-xs text-base-content/40">
                        {collector_version(source)} · {humanize(source.kind)}
                      </p>
                      <div
                        :if={collector_capabilities(source) != []}
                        class="mt-2 flex flex-wrap gap-1"
                      >
                        <span
                          :for={capability <- collector_capabilities(source)}
                          class="rounded-md bg-base-200 px-2 py-1 font-mono text-[10px] text-base-content/55"
                        >
                          {capability}
                        </span>
                      </div>
                    </td>
                    <td class="px-5 py-4">
                      <.collector_state_pill source={source} />
                      <p class="mt-1.5 font-mono text-[11px] text-base-content/40">
                        {collector_lease_expiry(source)}
                      </p>
                    </td>
                    <td class="px-5 py-4">
                      <.link
                        :if={Map.get(@resource_by_source, source.id)}
                        navigate={
                          ~p"/inventory/resources/#{Map.fetch!(@resource_by_source, source.id).id}"
                        }
                        class="font-medium transition hover:text-orange-600"
                      >
                        {Map.fetch!(@resource_by_source, source.id).display_name ||
                          Map.fetch!(@resource_by_source, source.id).name}
                      </.link>
                      <span
                        :if={is_nil(Map.get(@resource_by_source, source.id))}
                        class="text-xs text-base-content/35"
                      >
                        No resource reported
                      </span>
                    </td>
                    <td class="px-5 py-4">
                      <div class="flex flex-wrap items-center gap-2">
                        <.credential_pill
                          source={source}
                          credential={Map.get(@credential_by_source, source.id)}
                        />
                        <span
                          :if={collector_agent(source)}
                          class="font-mono text-[11px] text-base-content/40"
                        >
                          ID {short_installation_id(collector_agent(source).installation_id)}
                        </span>
                      </div>
                    </td>
                    <td class="px-5 py-4 font-mono text-xs text-base-content/55">
                      {format_time(Map.get(@last_inventory_by_source, source.id))}
                    </td>
                    <td class="px-5 py-4">
                      <div
                        :if={
                          Inventory.collector_manager?(@current_scope) &&
                            is_nil(Map.get(@credential_by_source, source.id))
                        }
                        class="flex justify-end gap-1"
                      >
                        <button
                          id={"rotate-collector-#{source.id}"}
                          type="button"
                          phx-click="rotate_collector"
                          phx-value-id={source.id}
                          data-confirm="Rotate this collector token? The current token will stop working immediately and the replacement is shown once."
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
                        >
                          Rotate token
                        </button>
                        <button
                          :if={collector_agent(source)}
                          id={"reset-collector-#{source.id}"}
                          type="button"
                          phx-click="reset_collector"
                          phx-value-id={source.id}
                          data-confirm="Reset this collector? Its current installation will be rejected and a new token will be issued. Historical inventory is retained."
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-amber-700 transition hover:bg-amber-500/10 dark:text-amber-400"
                        >
                          Reset
                        </button>
                        <button
                          id={"revoke-collector-#{source.id}"}
                          type="button"
                          phx-click="revoke_collector"
                          phx-value-id={source.id}
                          data-confirm="Revoke this collector credential? Existing inventory is retained."
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-rose-700 transition hover:bg-rose-500/10 dark:text-rose-400"
                        >
                          Revoke
                        </button>
                      </div>
                      <div
                        :if={
                          Inventory.collector_manager?(@current_scope) &&
                            Map.get(@credential_by_source, source.id)
                        }
                        class="flex justify-end gap-1"
                      >
                        <% credential = Map.fetch!(@credential_by_source, source.id) %>
                        <button
                          :if={credential.state == :active}
                          id={"quarantine-agent-credential-#{credential.id}"}
                          type="button"
                          phx-click="quarantine_agent_credential"
                          phx-value-id={credential.id}
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-amber-700 transition hover:bg-amber-500/10 dark:text-amber-400"
                        >
                          Quarantine
                        </button>
                        <button
                          :if={credential.state == :quarantined}
                          id={"unquarantine-agent-credential-#{credential.id}"}
                          type="button"
                          phx-click="unquarantine_agent_credential"
                          phx-value-id={credential.id}
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-emerald-700 transition hover:bg-emerald-500/10 dark:text-emerald-400"
                        >
                          Unquarantine
                        </button>
                        <button
                          :if={credential.state != :revoked}
                          id={"revoke-agent-credential-#{credential.id}"}
                          type="button"
                          phx-click="revoke_agent_credential"
                          phx-value-id={credential.id}
                          data-confirm="Permanently revoke this key credential? This cannot be undone."
                          class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-rose-700 transition hover:bg-rose-500/10 dark:text-rose-400"
                        >
                          Revoke
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :source, :map, required: true

  defp collector_state_pill(assigns) do
    state = collector_state(assigns.source)
    assigns = assign(assigns, :state, state)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
      @state == :connected && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
      @state == :disconnected && "bg-rose-500/10 text-rose-700 dark:text-rose-400",
      @state == :awaiting && "bg-amber-500/10 text-amber-700 dark:text-amber-400",
      @state == :disabled && "bg-base-content/10 text-base-content/55"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @state == :connected && "bg-emerald-500",
        @state == :disconnected && "bg-rose-500",
        @state == :awaiting && "bg-amber-500",
        @state == :disabled && "bg-base-content/35"
      ]} />
      {collector_state_label(@state)}
    </span>
    """
  end

  attr :source, :map, required: true
  attr :credential, :map, default: nil

  defp credential_pill(assigns) do
    ~H"""
    <div :if={@credential} id={"agent-credential-state-#{@credential.id}"} class="space-y-1">
      <span class={[
        "rounded-full px-2.5 py-1 text-xs font-medium",
        @credential.state == :active && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
        @credential.state == :quarantined && "bg-amber-500/10 text-amber-700 dark:text-amber-400",
        @credential.state in [:revoked, :expired] && "bg-rose-500/10 text-rose-700 dark:text-rose-400"
      ]}>
        {humanize(Atom.to_string(@credential.state))}
      </span>
      <p class="font-mono text-[11px] text-base-content/40">
        Expires {format_time(@credential.expires_at)}
      </p>
    </div>
    <span
      :if={is_nil(@credential)}
      class={[
        "rounded-full px-2.5 py-1 text-xs font-medium",
        @source.status == "active" && not is_nil(@source.token_hash) &&
          "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
        (@source.status != "active" || is_nil(@source.token_hash)) &&
          "bg-base-content/10 text-base-content/55"
      ]}
    >
      {credential_state(@source)}
    </span>
    """
  end

  defp disconnected?(agent) do
    agent.status != "active" || is_nil(agent.lease) || AgentLease.expired?(agent.lease)
  end

  defp credential_state(%{status: "active", token_hash: token_hash}) when not is_nil(token_hash),
    do: "Credential active"

  defp credential_state(%{status: "active"}), do: "No credential"
  defp credential_state(_source), do: "Credential revoked"

  defp load_operations(socket) do
    scope = socket.assigns.current_scope

    credential_by_source =
      scope
      |> Enrollment.list_agent_credentials()
      |> Enum.reduce(%{}, fn credential, credentials ->
        Map.put_new(credentials, credential.source_id, %{
          id: credential.id,
          expires_at: credential.expires_at,
          state: effective_credential_state(credential)
        })
      end)

    sources =
      scope
      |> Inventory.list_operational_sources()
      |> Enum.filter(&(&1.kind == "host_agent"))

    sources =
      if socket.assigns.disconnected_only?,
        do: Enum.filter(sources, &(collector_state(&1) == :disconnected)),
        else: sources

    socket
    |> assign(:credential_by_source, credential_by_source)
    |> assign(:last_inventory_by_source, Inventory.latest_observation_times(scope))
    |> assign(:resource_by_source, Inventory.latest_resources_by_source(scope))
    |> stream(:sources, sources, reset: true)
  end

  defp administer_agent_credential(socket, credential_id, action) do
    result =
      case action do
        :quarantine ->
          Enrollment.quarantine_agent_credential(socket.assigns.current_scope, credential_id)

        :unquarantine ->
          Enrollment.unquarantine_agent_credential(socket.assigns.current_scope, credential_id)

        :revoke ->
          Enrollment.revoke_agent_credential(socket.assigns.current_scope, credential_id)
      end

    case result do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> put_flash(:info, "Key credential #{action_label(action)}")
         |> load_operations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update key credential")}
    end
  end

  defp effective_credential_state(%{status: status, expires_at: expires_at}) do
    if status not in ["revoked", "expired"] &&
         DateTime.compare(expires_at, Renga.Time.utc_now_ms()) != :gt,
       do: :expired,
       else: String.to_existing_atom(status)
  end

  defp action_label(:quarantine), do: "quarantined"
  defp action_label(:unquarantine), do: "unquarantined"
  defp action_label(:revoke), do: "revoked"

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  defp source_dom_id(source), do: "collector-#{source.id}"

  defp collector_form(scope), do: scope |> collector_changeset(%{}) |> to_form(as: :collector)

  defp collector_installation_id(scope, source_id) do
    scope
    |> Inventory.list_operational_sources()
    |> Enum.find(&(&1.id == source_id))
    |> case do
      nil -> nil
      source -> source |> collector_agent() |> then(&(&1 && &1.installation_id))
    end
  end

  defp collector_changeset(scope, params) do
    %Source{
      organization_id: scope.organization_id,
      kind: "host_agent",
      status: "active"
    }
    |> Inventory.change_source(Map.merge(params, %{"kind" => "host_agent", "status" => "active"}))
  end

  defp collector_agent(%{agents: [agent]}), do: agent
  defp collector_agent(_source), do: nil

  defp collector_state(source) do
    cond do
      is_nil(collector_agent(source)) ->
        :not_enrolled

      disconnected?(collector_agent(source)) ->
        :disconnected

      true ->
        :connected
    end
  end

  defp collector_state_label(:connected), do: "Connected"
  defp collector_state_label(:disconnected), do: "Disconnected"
  defp collector_state_label(:not_enrolled), do: "Awaiting enrollment"

  defp collector_version(source) do
    case collector_agent(source) do
      %{version: version} when is_binary(version) -> "v#{version}"
      _agent -> "Not enrolled"
    end
  end

  defp collector_capabilities(source) do
    case collector_agent(source) do
      %{capabilities: capabilities} -> capabilities
      _agent -> []
    end
  end

  defp collector_lease_expiry(source) do
    case collector_agent(source) do
      %{lease: lease} -> lease_expiry(lease)
      _agent -> "Waiting for first check-in"
    end
  end

  defp short_installation_id(nil), do: "Legacy identity"

  defp short_installation_id(installation_id) do
    "#{String.slice(installation_id, 0, 8)}…#{String.slice(installation_id, -4, 4)}"
  end

  defp credential_heading(:created), do: "Collector created"
  defp credential_heading(:rotated), do: "Credential rotated"
  defp credential_heading(:reset), do: "Enrollment reset"

  defp credential_instructions(:reset),
    do: "The previous installation has been disconnected. Save the new setup values now."

  defp credential_instructions(_action),
    do: "Save these values now. The token cannot be shown again."

  defp lease_expiry(nil), do: "No lease"
  defp lease_expiry(lease), do: "expires #{format_time(lease.expires_at)}"

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp humanize(value), do: String.replace(value, "_", " ")
end
