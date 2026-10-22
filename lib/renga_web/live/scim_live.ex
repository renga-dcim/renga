defmodule RengaWeb.ScimLive do
  @moduledoc """
  Settings → SCIM: the organization's SCIM connection (RFD 16,
  "Connections"). Owners connect an OpenID Connect provider, issue and
  revoke the bearer tokens the provider calls Renga with, choose the default
  role, map directory groups to roles, and disable or re-enable the
  connection. A token is shown once, like an intake key. Renga.Scim
  re-checks all of it.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory.Changes
  alias Renga.Scim
  alias Renga.Scim.Connection

  @roles ~w(owner admin member viewer)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(:page_title, "SCIM")
     |> assign(:can_manage?, Scim.can_manage?(scope))
     |> assign(:issued_token, nil)
     |> assign(:token_form, token_form())
     |> assign(:connect_form, connect_form())
     |> load_connections()}
  end

  @impl true
  def handle_event("connect", %{"connection" => params}, socket) do
    case Scim.create_connection(socket.assigns.current_scope, params) do
      {:ok, _connection} ->
        {:noreply,
         socket
         |> put_flash(:info, "SCIM connection created. Issue a token for your provider next.")
         |> assign(:connect_form, connect_form())
         |> load_connections()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :connect_form, to_form(changeset, as: :connection))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("default_role", %{"default_role" => %{"role" => role}}, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Scim.update_default_role(scope, connection.id, role) do
      {:ok, _connection} ->
        {:noreply, socket |> put_flash(:info, "Default role saved") |> load_connections()}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("map_group", %{"group_id" => group_id, "role" => role}, socket) do
    case Scim.map_group(socket.assigns.current_scope, group_id, role) do
      {:ok, group} ->
        {:noreply, socket |> put_flash(:info, mapped_message(group)) |> load_connections()}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    case Scim.disable_connection(socket.assigns.current_scope, id) do
      {:ok, _connection} ->
        {:noreply, socket |> put_flash(:info, "SCIM connection disabled") |> load_connections()}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    case Scim.enable_connection(socket.assigns.current_scope, id) do
      {:ok, _connection} ->
        {:noreply, socket |> put_flash(:info, "SCIM connection enabled") |> load_connections()}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event(event, _params, socket) when event in ["new_token", "cancel_token"] do
    {:noreply, assign(socket, issued_token: nil, token_form: token_form())}
  end

  def handle_event("create_token", %{"token" => params}, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Scim.create_token(scope, connection.id, params) do
      {:ok, {_token, value}} ->
        {:noreply,
         socket
         |> assign(issued_token: value, token_form: token_form())
         |> load_connections()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset, as: :token))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    case Scim.revoke_token(socket.assigns.current_scope, id) do
      {:ok, token} ->
        {:noreply,
         socket |> put_flash(:info, "Token #{token.name} revoked") |> load_connections()}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_connections(socket)}

  defp refuse(socket, reason),
    do: socket |> put_flash(:error, refusal(reason)) |> load_connections()

  defp refusal(:too_many_tokens),
    do: "A connection holds at most #{Scim.max_active_tokens()} tokens. Revoke one first."

  defp refusal(:already_connected),
    do: "This organization already has an enabled SCIM connection. Disable it first."

  defp refusal(:provider_unavailable),
    do: "Its identity provider is disabled or removed, so the connection can't be enabled."

  defp refusal(:invalid_role), do: "Choose one of the built-in roles."
  defp refusal(:forbidden), do: "Only organization owners manage SCIM."
  defp refusal(_reason), do: "That changed in the meantime. Here is the current state."

  defp mapped_message(%{role: nil} = group), do: "#{group.display_name} no longer grants a role"

  defp mapped_message(group),
    do: "Members of #{group.display_name} now get #{group.role}"

  defp load_connections(%{assigns: %{can_manage?: false}} = socket),
    do:
      assign(socket,
        connection: nil,
        default_role_form: nil,
        history: [],
        groups: [],
        providers: []
      )

  defp load_connections(socket) do
    scope = socket.assigns.current_scope

    {enabled, history} =
      scope |> Scim.list_connections() |> Enum.split_with(&Connection.enabled?/1)

    connection = List.first(enabled)

    assign(socket,
      connection: connection,
      default_role_form: default_role_form(connection),
      history: history,
      groups: if(connection, do: Scim.list_groups(scope, connection.id), else: []),
      providers: if(connection, do: [], else: Scim.eligible_providers(scope))
    )
  end

  defp connect_form,
    do:
      to_form(Scim.change_connection(%Connection{}, %{"default_role" => "member"}),
        as: :connection
      )

  defp token_form, do: to_form(%{"name" => ""}, as: :token)

  defp default_role_form(nil), do: nil

  defp default_role_form(connection),
    do: to_form(%{"role" => connection.default_role || ""}, as: :default_role)

  defp role_options, do: for(role <- @roles, do: {String.capitalize(role), role})

  defp scim_url, do: RengaWeb.Endpoint.url() <> "/scim/v2"

  defp format_time(nil), do: "Never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:scim}
    >
      <.settings_page
        id="scim"
        title="SCIM"
        description="Let your identity provider add people, set their roles, and remove them the moment it does."
        class="max-w-4xl"
      >
        <p :if={!@can_manage?} id="scim-owners-only" class="text-sm text-fg-muted">
          Only organization owners manage SCIM.
        </p>

        <section
          :if={@can_manage? && is_nil(@connection)}
          id="scim-connect"
          class="space-y-3 rounded-lg border border-edge bg-surface p-4"
          aria-labelledby="scim-connect-heading"
        >
          <div>
            <h2 id="scim-connect-heading" class="text-sm font-medium text-fg">
              Connect an identity provider
            </h2>
            <p class="mt-1 text-xs text-fg-muted">
              Provisioned people sign in with this provider. Renga links each directory entry to the account whose ID token
              <span class="font-mono">sub</span>
              equals the entry's <span class="font-mono">externalId</span>.
            </p>
          </div>

          <p :if={@providers == []} id="scim-no-providers" class="text-sm text-fg-muted">
            No OpenID Connect provider is available to this organization. Add one first.
          </p>

          <.form
            :if={@providers != []}
            for={@connect_form}
            id="scim-connect-form"
            phx-submit="connect"
          >
            <.input
              field={@connect_form[:provider_id]}
              type="select"
              label="Identity provider"
              options={for provider <- @providers, do: {provider.display_name, provider.id}}
            />
            <.input
              field={@connect_form[:default_role]}
              type="select"
              label="Default role"
              prompt="None: only mapped groups grant access"
              options={role_options()}
            />
            <.button id="scim-connect-button" variant="primary" phx-disable-with="Connecting…">
              Connect
            </.button>
          </.form>
        </section>

        <section
          :if={@connection}
          id="scim-connection"
          class="space-y-4"
          aria-labelledby="scim-connection-heading"
        >
          <div class="space-y-3 rounded-lg border border-edge bg-surface p-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <h2 id="scim-connection-heading" class="text-sm font-medium text-fg">
                  {@connection.provider.display_name}
                </h2>
                <p class="mt-1 text-xs text-fg-muted">
                  Correlates on <span class="font-mono">{@connection.correlation_claim}</span>
                  · Connected {format_time(@connection.inserted_at)}
                </p>
              </div>
              <.button
                id="scim-disable"
                size="sm"
                variant="ghost"
                class="text-crit"
                phx-click={show_overlay("scim-disable-dialog")}
              >
                Disable
              </.button>
            </div>

            <div class="rounded-md bg-sunken px-3 py-2">
              <p class="text-xs text-fg-muted">SCIM base URL</p>
              <p id="scim-base-url" class="mt-1 break-all font-mono text-xs text-fg">
                {scim_url()}
              </p>
            </div>

            <.form for={@default_role_form} id="scim-default-role-form" phx-change="default_role">
              <.input
                field={@default_role_form[:role]}
                type="select"
                label="Default role"
                prompt="None: only mapped groups grant access"
                options={role_options()}
              />
            </.form>
            <p class="text-xs text-fg-muted">
              Every active, linked person gets the highest of this role and their groups' roles. Members you added by hand keep their own role.
            </p>
          </div>

          <.confirm_dialog
            id="scim-disable-dialog"
            title="Disable SCIM?"
            confirm_label="Disable"
            on_confirm={JS.push("disable", value: %{id: @connection.id})}
          >
            Its tokens stop working at once, and everyone it granted access to loses it. Members you added by hand keep theirs.
          </.confirm_dialog>

          <section id="scim-tokens" class="space-y-3" aria-labelledby="scim-tokens-heading">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 id="scim-tokens-heading" class="text-sm font-medium text-fg">Tokens</h2>
                <p class="mt-1 text-xs text-fg-muted">
                  Your provider sends one as a bearer token. Keep two to rotate without downtime.
                </p>
              </div>
              <.button
                :if={length(@connection.tokens) < Scim.max_active_tokens()}
                id="scim-new-token"
                size="sm"
                phx-click={JS.push("new_token") |> show_overlay("scim-token-panel")}
              >
                <.icon name="hero-key-mini" class="size-4" /> Issue token
              </.button>
            </div>

            <div
              id="scim-token-list"
              class="divide-y divide-line rounded-lg border border-edge bg-surface"
            >
              <p :if={@connection.tokens == []} class="px-4 py-8 text-center text-sm text-fg-muted">
                No tokens yet. Your provider can't reach Renga until you issue one.
              </p>
              <div
                :for={token <- @connection.tokens}
                id={"scim-token-#{token.id}"}
                class="flex flex-wrap items-center gap-3 px-3 py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium text-fg">{token.name}</p>
                  <p class="text-xs text-fg-muted">
                    Issued {format_time(token.inserted_at)} · Last used {format_time(
                      token.last_used_at
                    )}
                  </p>
                </div>
                <.button
                  id={"scim-token-#{token.id}-revoke"}
                  size="sm"
                  variant="ghost"
                  class="text-crit"
                  phx-click={show_overlay("scim-token-#{token.id}-dialog")}
                >
                  Revoke
                </.button>
                <.confirm_dialog
                  id={"scim-token-#{token.id}-dialog"}
                  title="Revoke this token?"
                  confirm_label="Revoke token"
                  on_confirm={JS.push("revoke_token", value: %{id: token.id})}
                >
                  Your provider's requests with it are refused at once.
                </.confirm_dialog>
              </div>
            </div>
          </section>

          <section id="scim-groups" class="space-y-3" aria-labelledby="scim-groups-heading">
            <div>
              <h2 id="scim-groups-heading" class="text-sm font-medium text-fg">Group roles</h2>
              <p class="mt-1 text-xs text-fg-muted">
                Groups appear once your provider pushes them. A mapping follows the group through renames; a deleted group's mapping goes with it.
              </p>
            </div>
            <div
              id="scim-group-list"
              class="divide-y divide-line rounded-lg border border-edge bg-surface"
            >
              <p :if={@groups == []} class="px-4 py-8 text-center text-sm text-fg-muted">
                No groups pushed yet.
              </p>
              <form
                :for={{group, members} <- @groups}
                id={"scim-group-#{group.id}"}
                phx-change="map_group"
                class="flex flex-wrap items-center gap-3 px-3 pt-3"
              >
                <input type="hidden" name="group_id" value={group.id} />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium text-fg">{group.display_name}</p>
                  <p class="text-xs text-fg-muted">
                    {members} {if members == 1, do: "member", else: "members"}
                  </p>
                </div>
                <.input
                  id={"scim-group-#{group.id}-role"}
                  name="role"
                  type="select"
                  value={group.role || ""}
                  options={[{"No role", ""} | role_options()]}
                  aria-label={"Role for #{group.display_name}"}
                />
              </form>
            </div>
          </section>
        </section>

        <section
          :if={@can_manage? && @history != []}
          id="scim-history"
          class="space-y-3"
          aria-labelledby="scim-history-heading"
        >
          <h2 id="scim-history-heading" class="text-sm font-medium text-fg">
            Disabled connections
          </h2>
          <div class="divide-y divide-line rounded-lg border border-edge bg-surface">
            <div
              :for={old <- @history}
              id={"scim-connection-#{old.id}"}
              class="flex flex-wrap items-center gap-3 px-3 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium text-fg">{old.provider.display_name}</p>
                <p class="text-xs text-fg-muted">Disabled {format_time(old.disabled_at)}</p>
              </div>
              <.button
                :if={is_nil(@connection)}
                id={"scim-connection-#{old.id}-enable"}
                size="sm"
                phx-click={JS.push("enable", value: %{id: old.id})}
              >
                Enable
              </.button>
            </div>
          </div>
        </section>
      </.settings_page>

      <.side_panel
        :if={@connection}
        id="scim-token-panel"
        title="Issue a SCIM token"
        description="Paste it into your identity provider's provisioning settings with the base URL."
        on_cancel={JS.push("cancel_token")}
      >
        <.form
          :if={is_nil(@issued_token)}
          for={@token_form}
          id="scim-token-form"
          phx-submit="create_token"
        >
          <.input
            field={@token_form[:name]}
            type="text"
            label="Token name"
            placeholder="Okta provisioning"
            autocomplete="off"
          />
          <.button id="scim-create-token" type="submit" variant="primary">Issue token</.button>
        </.form>

        <div :if={@issued_token} id="scim-token-credentials" class="space-y-4">
          <div class="flex gap-2.5 rounded-md bg-sunken px-3 py-2">
            <.icon name="hero-check-circle-mini" class="mt-0.5 size-4 shrink-0 text-ok" />
            <div>
              <p class="text-sm font-medium text-fg">Token issued</p>
              <p class="text-xs text-fg-muted">
                Save it now. Renga stores only its hash and cannot show it again.
              </p>
            </div>
          </div>
          <div class="flex items-center gap-3 rounded-md border border-edge px-3 py-2">
            <div class="min-w-0 flex-1">
              <p class="text-xs text-fg-muted">Bearer token</p>
              <p id="issued-scim-token" class="mt-1 break-all font-mono text-xs text-fg">
                {@issued_token}
              </p>
            </div>
            <button
              id="copy-scim-token"
              type="button"
              phx-hook="CopyToClipboard"
              data-copy-target="#issued-scim-token"
              data-copy-status="#copy-scim-token-status"
              aria-label="Copy SCIM token"
              class="grid min-h-tap min-w-tap size-8 shrink-0 cursor-pointer place-items-center rounded-md border border-edge bg-surface text-fg-muted transition-colors hover:bg-sunken hover:text-fg focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
            >
              <span data-copy-icon><.icon name="hero-clipboard" class="size-4" /></span>
              <span data-copied-icon class="hidden">
                <.icon name="hero-check" class="size-4 text-ok" />
              </span>
            </button>
            <span
              id="copy-scim-token-status"
              class="sr-only"
              role="status"
              aria-live="polite"
              aria-atomic="true"
            />
          </div>
          <.button
            id="scim-token-saved"
            phx-click={JS.push("cancel_token") |> hide_overlay("scim-token-panel")}
          >
            I saved this token
          </.button>
        </div>
      </.side_panel>
    </Layouts.app>
    """
  end
end
