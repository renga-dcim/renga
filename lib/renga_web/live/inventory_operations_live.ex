defmodule RengaWeb.InventoryOperationsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.AgentLease

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
        do: ~p"/inventory/operations?disconnected=true",
        else: ~p"/inventory/operations"

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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="collector-operations" class="space-y-10">
        <header class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              Collection plane
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Collectors</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
              Installations appear automatically after authenticating with an organization intake key.
            </p>
          </div>
          <button
            :if={Inventory.collector_manager?(@current_scope)}
            id="new-intake-key-button"
            type="button"
            phx-click="new_intake_key"
            class="inline-flex items-center gap-2 rounded-xl bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white shadow-sm shadow-orange-500/20 transition hover:-translate-y-0.5 hover:bg-orange-600"
          >
            <.icon name="hero-key" class="size-4" /> Create intake key
          </button>
        </header>

        <section id="intake-key-management" class="space-y-4" aria-labelledby="intake-keys-heading">
          <div>
            <h2 id="intake-keys-heading" class="text-lg font-semibold">Organization intake keys</h2>
            <p class="mt-1 text-sm text-base-content/50">
              Multiple active keys allow a fleet-wide rotation without downtime.
            </p>
          </div>

          <div
            :if={@show_new_key?}
            id="new-intake-key-panel"
            class="overflow-hidden rounded-2xl border border-orange-500/20 bg-base-100 shadow-lg shadow-orange-500/5"
          >
            <div class="flex items-start justify-between gap-4 border-b border-base-content/10 px-6 py-5">
              <div>
                <h3 class="font-semibold">Create an intake API key</h3>
                <p class="mt-1 text-sm text-base-content/50">
                  One key can be deployed to every collector in this organization.
                </p>
              </div>
              <button
                id="cancel-intake-key"
                type="button"
                phx-click="cancel_intake_key"
                aria-label="Close intake key setup"
                class="rounded-lg p-2 text-base-content/40 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <div :if={is_nil(@issued_token)} class="p-6">
              <.form
                for={@key_form}
                id="new-intake-key-form"
                phx-change="validate_intake_key"
                phx-submit="create_intake_key"
                class="max-w-xl space-y-5"
              >
                <.input
                  field={@key_form[:name]}
                  type="text"
                  label="Key name"
                  placeholder="Production fleet"
                  autocomplete="off"
                />
                <button
                  id="create-intake-key-button"
                  type="submit"
                  class="rounded-xl bg-orange-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-orange-600"
                >
                  Create key
                </button>
              </.form>
            </div>

            <div :if={@issued_token} id="intake-key-credentials" class="space-y-5 p-6">
              <div class="flex gap-3 rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4">
                <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-emerald-600" />
                <div>
                  <p class="text-sm font-semibold">Intake key created</p>
                  <p class="mt-1 text-xs leading-5 text-base-content/55">
                    Save this key now. Renga stores only its hash and cannot show it again.
                  </p>
                </div>
              </div>
              <div class="rounded-xl bg-base-200/70 p-4">
                <p class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                  Intake API key
                </p>
                <p id="issued-intake-key" class="mt-2 break-all font-mono text-xs">
                  {@issued_token}
                </p>
              </div>
              <div class="rounded-xl border border-base-content/10 bg-slate-950 p-4 text-slate-100">
                <p class="mb-3 text-xs font-semibold uppercase tracking-wider text-slate-400">
                  agent.toml
                </p>
                <code
                  phx-no-curly-interpolation
                  class="block whitespace-pre-wrap break-all font-mono text-xs leading-6"
                >
                  {"renga_url = \"#{RengaWeb.Endpoint.url()}\"\ntoken = \"#{@issued_token}\"\ninstallation_id = \"UNIQUE_INSTALLATION_UUID\""}
                </code>
              </div>
              <button
                id="finish-intake-key-setup"
                type="button"
                phx-click="cancel_intake_key"
                class="rounded-xl border border-base-content/15 px-4 py-2.5 text-sm font-semibold transition hover:bg-base-200"
              >
                I saved this key
              </button>
            </div>
          </div>

          <div class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm">
            <div id="intake-api-keys" phx-update="stream" class="divide-y divide-base-content/10">
              <div
                id="intake-api-keys-empty"
                class="hidden only:block px-5 py-10 text-center text-sm text-base-content/45"
              >
                No intake keys yet.
              </div>
              <div
                :for={{id, key} <- @streams.intake_api_keys}
                id={id}
                class="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p class="font-semibold">{key.name}</p>
                  <p class="mt-1 text-xs text-base-content/45">
                    Created {format_time(key.inserted_at)}
                  </p>
                </div>
                <div class="flex items-center gap-3">
                  <span class={[
                    "rounded-full px-2.5 py-1 text-xs font-medium",
                    key.status == "active" &&
                      "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
                    key.status == "revoked" && "bg-base-content/10 text-base-content/55"
                  ]}>
                    {String.capitalize(key.status)}
                  </span>
                  <button
                    :if={key.status == "active" && Inventory.collector_manager?(@current_scope)}
                    id={"revoke-intake-key-#{key.id}"}
                    type="button"
                    phx-click="revoke_intake_key"
                    phx-value-id={key.id}
                    data-confirm="Revoke this shared key? Every collector still using it will be rejected."
                    class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-rose-700 transition hover:bg-rose-500/10 dark:text-rose-400"
                  >
                    Revoke
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="collector-list" class="space-y-4" aria-labelledby="collectors-heading">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 id="collectors-heading" class="text-lg font-semibold">Discovered installations</h2>
              <p class="mt-1 text-sm text-base-content/50">
                Runtime health and inventory provenance remain specific to each installation.
              </p>
            </div>
            <.form for={@filter_form} id="collector-filters" phx-change="filter">
              <.input field={@filter_form[:disconnected]} type="checkbox" label="Disconnected only" />
            </.form>
          </div>

          <div class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm">
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-base-content/10 text-left text-sm">
                <thead class="bg-base-200/70 text-xs uppercase tracking-wider text-base-content/45">
                  <tr>
                    <th class="px-5 py-3.5 font-semibold">Collector</th>
                    <th class="px-5 py-3.5 font-semibold">Connection</th>
                    <th class="px-5 py-3.5 font-semibold">Resource provenance</th>
                    <th class="px-5 py-3.5 font-semibold">Installation</th>
                    <th class="px-5 py-3.5 font-semibold">Last inventory</th>
                  </tr>
                </thead>
                <tbody id="collectors" phx-update="stream" class="divide-y divide-base-content/10">
                  <tr id="collectors-empty" class="hidden only:table-row">
                    <td colspan="5" class="px-5 py-12 text-center text-sm text-base-content/45">
                      No discovered collectors match this view.
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
                        {collector_version(source)}
                      </p>
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
                    <td class="px-5 py-4 font-mono text-xs text-base-content/55">
                      {short_installation_id(collector_agent(source).installation_id)}
                      <p class="mt-1 font-sans text-[11px] text-base-content/40">
                        {auth_method_label(collector_agent(source).last_auth_method)}
                      </p>
                      <p
                        :if={collector_agent(source).last_legacy_authenticated_at}
                        class="mt-1 font-sans text-[11px] text-amber-700 dark:text-amber-400"
                      >
                        Legacy source token last used {format_time(
                          collector_agent(source).last_legacy_authenticated_at
                        )}
                      </p>
                    </td>
                    <td class="px-5 py-4 font-mono text-xs text-base-content/55">
                      {format_time(Map.get(@last_inventory_by_source, source.id))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  attr :source, :map, required: true

  defp collector_state_pill(assigns) do
    state = if disconnected?(collector_agent(assigns.source)), do: :disconnected, else: :connected
    assigns = assign(assigns, :state, state)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
      @state == :connected && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
      @state == :disconnected && "bg-rose-500/10 text-rose-700 dark:text-rose-400"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @state == :connected && "bg-emerald-500",
        @state == :disconnected && "bg-rose-500"
      ]} />
      {if(@state == :connected, do: "Connected", else: "Disconnected")}
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
    |> assign(:last_inventory_by_source, Inventory.latest_observation_times(scope))
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

  defp short_installation_id(nil), do: "Legacy identity"

  defp short_installation_id(installation_id) do
    "#{String.slice(installation_id, 0, 8)}…#{String.slice(installation_id, -4, 4)}"
  end

  defp auth_method_label("intake_api_key"), do: "Organization intake key"
  defp auth_method_label("legacy_source_token"), do: "Legacy source token"
  defp auth_method_label(nil), do: "Authentication unknown"

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
