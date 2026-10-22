defmodule RengaWeb.OrganizationProviderLive do
  @moduledoc """
  Settings → Identity providers: the organization's own OpenID Connect
  providers, such as its Okta or Microsoft Entra ID tenant (RFD 15,
  "Organization providers"). Owners add one with the callback URL it shows,
  and new settings stay pending until the owner's own test sign-in against
  them works, which activates them. Everyone else is told who manages them.
  `Renga.Accounts.OrganizationProviders` re-checks every change.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationProviders

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Identity providers", manage?: OrganizationProviders.manage?(scope))
     |> assign(editing: nil, new_id: nil, form: to_form(%{}, as: "provider"))
     |> load()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil, new_id: OrganizationProviders.new_id())
     |> assign(:form, to_form(%{"allow_sign_up" => "false"}, as: "provider"))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, load(socket)}

      %{provider: provider, revision: revision} ->
        {:noreply,
         socket
         |> assign(editing: provider, new_id: nil)
         |> assign(:form, to_form(form_values(provider, revision), as: "provider"))}
    end
  end

  def handle_event("save", %{"provider" => params}, %{assigns: %{editing: nil}} = socket) do
    attrs =
      params
      |> revision_attrs()
      |> Map.merge(%{
        "id" => socket.assigns.new_id,
        "display_name" => params["display_name"],
        "issuer" => params["issuer"]
      })

    case OrganizationProviders.create(socket.assigns.current_scope, attrs) do
      {:ok, {provider, _revision}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{provider.display_name} added. Test its sign-in to turn it on.")
         |> close_overlay("provider-panel")
         |> assign(new_id: nil)
         |> load()}

      error ->
        {:noreply, failed(socket, error, params)}
    end
  end

  def handle_event("save", %{"provider" => params}, %{assigns: %{editing: provider}} = socket) do
    scope = socket.assigns.current_scope

    with {:ok, provider} <-
           OrganizationProviders.update_display(scope, provider, %{
             "display_name" => params["display_name"]
           }),
         {:ok, _} <- propose(scope, provider, revision_attrs(params)) do
      {:noreply,
       socket
       |> put_flash(:info, "#{provider.display_name} saved.")
       |> close_overlay("provider-panel")
       |> assign(editing: nil)
       |> load()}
    else
      error -> {:noreply, failed(socket, error, params)}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    with %{provider: provider} <- find(socket, id),
         {:ok, {token, _test}} <-
           OrganizationProviders.create_test(socket.assigns.current_scope, provider) do
      {:noreply, redirect(socket, to: ~p"/users/providers/test/#{token}")}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event(action, %{"id" => id}, socket)
      when action in ~w(discard enable disable remove) do
    fun =
      case action do
        "discard" -> &OrganizationProviders.discard_pending/2
        "enable" -> &OrganizationProviders.enable/2
        "disable" -> &OrganizationProviders.disable/2
        "remove" -> &OrganizationProviders.remove/2
      end

    with %{provider: provider} <- find(socket, id),
         {:ok, _provider} <- fun.(socket.assigns.current_scope, provider) do
      {:noreply, socket |> put_flash(:info, done(action, provider)) |> load()}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  # Saving only the name proposes no new settings.
  defp propose(scope, provider, attrs) do
    case OrganizationProviders.propose_revision(scope, provider, attrs) do
      {:error, :no_changes} -> {:ok, provider}
      result -> result
    end
  end

  defp failed(socket, {:error, %Ecto.Changeset{} = changeset}, params) do
    errors =
      for {field, {message, opts}} <- changeset.errors,
          do: {field, {message, opts}}

    assign(socket, :form, to_form(params, as: "provider", errors: errors, action: :insert))
  end

  defp failed(socket, error, _params), do: refused(socket, error)

  defp refused(socket, {:error, :forbidden}),
    do:
      socket
      |> put_flash(:error, "Only organization owners can change identity providers.")
      |> load()

  defp refused(socket, {:error, :no_encryption_key}),
    do: put_flash(socket, :error, "This server can't store client secrets yet. Ask its operator.")

  defp refused(socket, {:error, :nothing_pending}),
    do: socket |> put_flash(:error, "There are no new settings to test.") |> load()

  defp refused(socket, {:error, :no_active_revision}),
    do:
      put_flash(
        socket,
        :error,
        "A new provider has only these settings. Edit or remove it instead."
      )

  defp refused(socket, _error),
    do: socket |> put_flash(:error, "That provider changed. Try again.") |> load()

  defp done("discard", provider), do: "Discarded the new settings for #{provider.display_name}."
  defp done("enable", provider), do: "Sign-in with #{provider.display_name} is on."
  defp done("disable", provider), do: "Sign-in with #{provider.display_name} is off."
  defp done("remove", provider), do: "#{provider.display_name} removed."

  defp revision_attrs(params) do
    %{
      "client_id" => params["client_id"],
      "client_secret" => params["client_secret"],
      "scopes" => split(params["scopes"]),
      "email_domains" => split(params["email_domains"]),
      "allow_sign_up" => params["allow_sign_up"] == "true"
    }
  end

  defp split(nil), do: []
  defp split(value), do: value |> String.split([",", " ", "\n"], trim: true)

  defp form_values(provider, %Revision{} = revision) do
    %{
      "display_name" => provider.display_name,
      "issuer" => provider.issuer,
      "client_id" => revision.client_id,
      "scopes" => Enum.join(revision.scopes, ", "),
      "email_domains" => Enum.join(revision.email_domains, ", "),
      "allow_sign_up" => to_string(revision.allow_sign_up)
    }
  end

  defp find(socket, id), do: Enum.find(socket.assigns.providers, &(&1.provider.id == id))

  defp load(socket) do
    providers =
      if socket.assigns.manage? do
        for provider <- OrganizationProviders.list(socket.assigns.current_scope) do
          active = IdentityProviders.active_revision(provider)
          pending = IdentityProviders.pending_revision(provider)
          %{provider: provider, active: active, pending: pending, revision: pending || active}
        end
      else
        []
      end

    assign(socket, :providers, providers)
  end

  defp callback_url(id), do: url(~p"/users/auth/#{id}/callback")

  defp status(%{provider: %IdentityProvider{active_revision: nil}}),
    do: "Waiting for a test sign-in"

  defp status(%{provider: %IdentityProvider{enabled: false}}), do: "Off"
  defp status(%{pending: %Revision{}}), do: "On · new settings waiting for a test sign-in"
  defp status(_entry), do: "On"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:identity_providers}
    >
      <.settings_page
        id="identity-providers"
        title="Identity providers"
        description="Let members sign in with your organization's own OpenID Connect provider, such as Okta or Microsoft Entra ID. It signs people in to this organization only."
        class="max-w-4xl"
      >
        <:actions>
          <.button
            :if={@manage?}
            id="new-provider"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("provider-panel")}
          >
            Add provider
          </.button>
        </:actions>

        <p :if={!@manage?} id="providers-owners-only" class="text-sm text-fg-muted">
          Only organization owners can see and change identity providers.
        </p>

        <.table
          :if={@manage?}
          id="provider-list"
          rows={@providers}
          row_id={&"provider-#{&1.provider.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={entry} label="Provider" class="py-2">
            <span class="block font-medium text-fg">{entry.provider.display_name}</span>
            <span class="block truncate font-mono text-xs text-fg-muted">
              {entry.provider.issuer}
            </span>
          </:col>
          <:col :let={entry} label="Status">
            <span id={"provider-#{entry.provider.id}-status"} class="text-sm text-fg-muted">
              {status(entry)}
            </span>
          </:col>
          <:col :let={entry} label="Callback URL">
            <span class="block break-all font-mono text-xs text-fg-muted">
              {callback_url(entry.provider.id)}
            </span>
          </:col>
          <:action :let={entry}>
            <button
              :if={entry.pending}
              id={"provider-#{entry.provider.id}-test"}
              type="button"
              phx-click="test"
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Test sign-in
            </button>
            <button
              id={"provider-#{entry.provider.id}-edit"}
              type="button"
              phx-click={
                JS.push("edit", value: %{id: entry.provider.id}) |> show_overlay("provider-panel")
              }
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Edit
            </button>
            <button
              :if={entry.pending && entry.active}
              id={"provider-#{entry.provider.id}-discard"}
              type="button"
              phx-click="discard"
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Discard new settings
            </button>
            <button
              :if={entry.active}
              id={"provider-#{entry.provider.id}-toggle"}
              type="button"
              phx-click={if entry.provider.enabled, do: "disable", else: "enable"}
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              {if entry.provider.enabled, do: "Turn off", else: "Turn on"}
            </button>
            <button
              id={"provider-#{entry.provider.id}-remove"}
              type="button"
              phx-click={show_overlay("remove-provider-#{entry.provider.id}")}
              class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
            >
              Remove
            </button>
          </:action>
          <:empty>
            No identity providers yet. Add your organization's OpenID Connect provider to let
            members sign in with it.
          </:empty>
        </.table>
      </.settings_page>

      <.confirm_dialog
        :for={entry <- @providers}
        id={"remove-provider-#{entry.provider.id}"}
        title={"Remove #{entry.provider.display_name}?"}
        confirm_label="Remove provider"
        on_confirm={JS.push("remove", value: %{id: entry.provider.id})}
      >
        Nobody can sign in with it afterwards, and its saved client secret is deleted.
      </.confirm_dialog>

      <.side_panel
        :if={@manage?}
        id="provider-panel"
        title={if @editing, do: "Edit #{@editing.display_name}", else: "Add a provider"}
        description={
          if @editing,
            do:
              "Changes to the client or sign-in rules wait for a test sign-in before they take effect.",
            else:
              "Register Renga at your identity provider with this callback URL, then enter the client it gives you."
        }
      >
        <div :if={@new_id} id="provider-callback" class="mb-4 rounded-md bg-sunken p-3">
          <p class="text-xs text-fg-muted">Callback URL</p>
          <p class="break-all font-mono text-sm text-fg">{callback_url(@new_id)}</p>
        </div>
        <.form for={@form} id="provider-form" phx-submit="save">
          <.input field={@form[:display_name]} type="text" label="Name" required autocomplete="off" />
          <.input
            :if={!@editing}
            field={@form[:issuer]}
            type="url"
            label="Issuer URL"
            placeholder="https://login.example.com"
            required
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            required
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:client_secret]}
            type="password"
            label={
              if @editing,
                do: "Client secret (leave empty to keep the saved one)",
                else: "Client secret"
            }
            required={!@editing}
            autocomplete="new-password"
          />
          <.input
            field={@form[:email_domains]}
            type="text"
            label="Allowed email domains (optional, comma-separated)"
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:scopes]}
            type="text"
            label="Extra scopes (optional)"
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:allow_sign_up]}
            type="checkbox"
            label="Create a Renga account for someone signing in for the first time"
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("provider-panel")}>Cancel</.button>
            <.button id="provider-save" variant="primary" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end
end
